# Public-data Postgres: the two databases Retool apps read.
#
#   jobs_ingest     raw rows from public sources, loaded only by ingest_loader
#   jobs_analytics  serving tables rebuilt from jobs_ingest (via postgres_fdw)
#                   by analytics_builder, plus the provenance/citation table
#
# Retool connects as retool_reader: SELECT only, on both. Only tables that
# data/tables.yaml marks publish* are ever loaded; see data/publication-review.md.
#
# Not the blueprint's azure-database module: that one hard-codes
# azure.extensions to Retool's needs (UUID-OSSP,VECTOR), and this data needs
# pg_trgm (name matching) and postgres_fdw (ingest -> analytics).

resource "azurerm_private_dns_zone" "data" {
  name                = "${var.prefix}-data-pdns.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "data" {
  name                = "${var.prefix}-data-vnet-link"
  private_dns_zone_id = azurerm_private_dns_zone.data.id
  virtual_network_id  = module.vnet.vnet_id
}

resource "random_password" "data_admin" {
  length  = 32
  special = false
}

resource "azurerm_postgresql_flexible_server" "data" {
  name                          = "${var.prefix}-data"
  resource_group_name           = azurerm_resource_group.main.name
  location                      = var.location
  version                       = "16"
  sku_name                      = var.data_db_sku
  storage_mb                    = var.data_db_storage_mb
  auto_grow_enabled             = true
  backup_retention_days         = 7
  administrator_login           = "jobsadmin"
  administrator_password        = random_password.data_admin.result
  public_network_access_enabled = false
  delegated_subnet_id           = module.vnet.postgres_subnet_id
  private_dns_zone_id           = azurerm_private_dns_zone.data.id
  tags                          = var.tags

  maintenance_window {
    day_of_week = 0
    start_hour  = 7
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.data]

  lifecycle {
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_configuration" "data_extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.data.id
  value     = "PG_TRGM,POSTGRES_FDW,UUID-OSSP"
}

# Encrypted connections only, TLS 1.2+.
resource "azurerm_postgresql_flexible_server_configuration" "data_tls" {
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.data.id
  value     = "on"
}

resource "azurerm_postgresql_flexible_server_database" "data" {
  for_each  = toset(["jobs_ingest", "jobs_analytics"])
  name      = each.key
  server_id = azurerm_postgresql_flexible_server.data.id
  collation = "en_US.utf8"
  charset   = "utf8"
}

# Second database on Retool's own server for the nonprod lane, and one for
# Infisical's state (managed + backed up, instead of the chart's in-cluster PG).
resource "azurerm_postgresql_flexible_server_database" "main_extra" {
  for_each  = toset(concat(["infisical"], var.enable_nonprod ? ["retool_nonprod"] : []))
  name      = each.key
  server_id = "${azurerm_resource_group.main.id}/providers/Microsoft.DBforPostgreSQL/flexibleServers/${var.prefix}-main"
  collation = "en_US.utf8"
  charset   = "utf8"

  depends_on = [module.db-main]
}

# ---------- login roles ----------
# Generated here, stored in Key Vault (the bootstrap root of trust), applied to
# Postgres by the in-cluster db-bootstrap Job. Infisical then becomes where
# apps get them from (infra/secrets).

locals {
  db_roles = {
    "data-admin"             = random_password.data_admin.result
    "data-ingest-loader"     = random_password.role["ingest_loader"].result
    "data-analytics-builder" = random_password.role["analytics_builder"].result
    "data-analytics-fdw"     = random_password.role["analytics_fdw"].result
    "data-retool-reader"     = random_password.role["retool_reader"].result
    "main-infisical"         = random_password.role["infisical"].result
  }
}

resource "random_password" "role" {
  for_each = toset(["ingest_loader", "analytics_builder", "analytics_fdw", "retool_reader", "infisical"])
  length   = 32
  special  = false
}

resource "azurerm_key_vault_secret" "db_roles" {
  for_each         = local.db_roles
  name             = "db-${each.key}"
  value_wo         = each.value
  value_wo_version = 1
  key_vault_id     = module.vnet.key_vault_id
}

# ---------- db-bootstrap Job ----------

module "ns_data" {
  source = "../modules/kv-secretstore"

  name                = "data"
  prefix              = var.prefix
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  key_vault_id        = module.vnet.key_vault_id
  key_vault_uri       = module.vnet.key_vault_uri
  oidc_issuer_url     = module.aks.outputs.oidc_issuer_url
  tags                = var.tags

  depends_on = [module.aks]
}

resource "kubectl_manifest" "db_bootstrap_secret" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata   = { name = "db-bootstrap", namespace = module.ns_data.namespace }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { kind = "SecretStore", name = module.ns_data.secret_store_name }
      target          = { name = "db-bootstrap", creationPolicy = "Owner" }
      data = concat(
        [for k in keys(local.db_roles) : {
          secretKey = k
          remoteRef = { key = "db-${k}" }
        }],
        [{ secretKey = "main-admin", remoteRef = { key = module.db-main.outputs.master_secret_name } }],
      )
    }
  })
  depends_on = [module.ns_data, azurerm_key_vault_secret.db_roles]
}

resource "kubernetes_config_map_v1" "db_bootstrap_sql" {
  metadata {
    name      = "db-bootstrap-sql"
    namespace = module.ns_data.namespace
  }
  data = {
    "data.sql" = file("${path.module}/../../data/sql/bootstrap_data.sql")
    "main.sql" = file("${path.module}/../../data/sql/bootstrap_main.sql")
  }
}

# Re-runs whenever the SQL changes (name carries its hash). Idempotent SQL.
resource "kubernetes_job_v1" "db_bootstrap" {
  metadata {
    name      = "db-bootstrap-${substr(sha1(join("", values(kubernetes_config_map_v1.db_bootstrap_sql.data))), 0, 8)}"
    namespace = module.ns_data.namespace
  }
  spec {
    backoff_limit              = 3
    ttl_seconds_after_finished = 86400
    template {
      metadata {}
      spec {
        restart_policy                  = "Never"
        automount_service_account_token = false
        security_context {
          run_as_non_root = true
          run_as_user     = 70
          seccomp_profile { type = "RuntimeDefault" }
        }
        container {
          name    = "psql"
          image   = "postgres:16-alpine"
          command = ["/bin/sh", "-ec"]
          args = [<<-EOT
            export PGSSLMODE=require
            PGPASSWORD="$MAIN_ADMIN" psql -v ON_ERROR_STOP=1 -h "$MAIN_HOST" -U "$MAIN_USER" -d postgres \
              -v admin="$MAIN_USER" -v infisical_pw="$INFISICAL_PW" -f /sql/main.sql
            PGPASSWORD="$DATA_ADMIN" psql -v ON_ERROR_STOP=1 -h "$DATA_HOST" -U jobsadmin -d postgres \
              -v admin=jobsadmin -v data_host="$DATA_HOST" \
              -v ingest_loader_pw="$INGEST_PW" -v analytics_builder_pw="$BUILDER_PW" \
              -v analytics_fdw_pw="$FDW_PW" -v retool_reader_pw="$READER_PW" -f /sql/data.sql
          EOT
          ]
          env {
            name  = "MAIN_HOST"
            value = module.db-main.outputs.address
          }
          env {
            name  = "MAIN_USER"
            value = module.db-main.outputs.username
          }
          env {
            name  = "DATA_HOST"
            value = azurerm_postgresql_flexible_server.data.fqdn
          }
          dynamic "env" {
            for_each = {
              MAIN_ADMIN   = "main-admin"
              INFISICAL_PW = "main-infisical"
              DATA_ADMIN   = "data-admin"
              INGEST_PW    = "data-ingest-loader"
              BUILDER_PW   = "data-analytics-builder"
              FDW_PW       = "data-analytics-fdw"
              READER_PW    = "data-retool-reader"
            }
            content {
              name = env.key
              value_from {
                secret_key_ref {
                  name = "db-bootstrap"
                  key  = env.value
                }
              }
            }
          }
          volume_mount {
            name       = "sql"
            mount_path = "/sql"
          }
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities { drop = ["ALL"] }
          }
        }
        volume {
          name = "sql"
          config_map { name = kubernetes_config_map_v1.db_bootstrap_sql.metadata[0].name }
        }
      }
    }
  }
  wait_for_completion = true
  timeouts { create = "10m" }

  depends_on = [
    kubectl_manifest.db_bootstrap_secret,
    azurerm_postgresql_flexible_server_database.data,
    azurerm_postgresql_flexible_server_database.main_extra,
    azurerm_postgresql_flexible_server_configuration.data_extensions,
  ]
}
