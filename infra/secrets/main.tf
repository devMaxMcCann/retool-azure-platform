# Stage 2: Infisical as the app-secrets layer.
#
# infra/platform installs Infisical; this root configures it. They are separate
# because this one needs an Infisical admin credential, which can only exist
# after a human creates the first admin in the UI (autoBootstrap is off on
# purpose). Run order and the one-time manual steps are in README.md here.
#
# What it builds:
#   project  data-platform, environment demo
#   folders  /ingest  /analytics  /retool   -- one per consumer, so each
#            machine identity can be scoped to its own folder
#   secrets  the data-DB role credentials, copied from Key Vault with
#            ephemeral reads + write-only values, so no password lands in
#            this root's state
#   identity one per consuming namespace, Kubernetes auth, bound to exactly
#            one service account
#   sync     an InfisicalSecret in each consuming namespace -> a native Secret

data "azurerm_postgresql_flexible_server" "data" {
  name                = "${var.prefix}-data"
  resource_group_name = "${var.prefix}-platform"
}

data "azurerm_key_vault" "main" {
  name                = var.key_vault_name
  resource_group_name = "${var.prefix}-platform"
}

locals {
  data_host = data.azurerm_postgresql_flexible_server.data.fqdn

  # Which DB role each consumer logs in as, and which database it uses.
  # Each consumer sees ONLY its own folder.
  consumers = {
    ingest = {
      namespace = "ingest"
      sa        = "ingest"
      role      = "ingest_loader"
      database  = "jobs_ingest"
      kv_secret = "db-data-ingest-loader"
    }
    analytics = {
      namespace = "ingest" # the analytics builder runs as a CronJob beside the loaders
      sa        = "analytics"
      role      = "analytics_builder"
      database  = "jobs_analytics"
      kv_secret = "db-data-analytics-builder"
    }
  }

  # Every folder that gets PG* secrets. Retool is not a Kubernetes consumer: on
  # the free tier its resource is configured in the UI, so /retool is where the
  # operator reads the read-only credentials from (no identity, no sync).
  pg_targets = merge(
    { for k, v in local.consumers : k => { role = v.role, database = v.database, kv_secret = v.kv_secret } },
    { retool = { role = "retool_reader", database = "jobs_analytics", kv_secret = "db-data-retool-reader" } },
  )
}

resource "infisical_project" "data" {
  name                       = "data-platform"
  slug                       = "data-platform"
  description                = "App-to-app secrets for the public-data pipeline and the Retool resources that read it."
  should_create_default_envs = false
  # audit_log_retention_days is a paid-plan setting on self-hosted Infisical
  # ("plan limit reached"); the free tier keeps its default retention.
}

resource "infisical_project_environment" "demo" {
  name       = "demo"
  slug       = "demo"
  project_id = infisical_project.data.id
}

resource "infisical_secret_folder" "consumer" {
  for_each         = local.pg_targets
  name             = each.key
  folder_path      = "/"
  environment_slug = infisical_project_environment.demo.slug
  project_id       = infisical_project.data.id
}

# ---------------------------------------------------------------- DB secrets

ephemeral "azurerm_key_vault_secret" "role" {
  for_each     = local.pg_targets
  name         = each.value.kv_secret
  key_vault_id = data.azurerm_key_vault.main.id
}

resource "infisical_secret" "pg" {
  # PGHOST/PGUSER/... so libpq and psycopg pick them up with no app config.
  for_each = merge([for c, v in local.pg_targets : {
    "${c}/PGHOST"     = { folder = c, value = local.data_host }
    "${c}/PGPORT"     = { folder = c, value = "5432" }
    "${c}/PGDATABASE" = { folder = c, value = v.database }
    "${c}/PGUSER"     = { folder = c, value = v.role }
    "${c}/PGSSLMODE"  = { folder = c, value = "require" }
  }]...)
  name         = split("/", each.key)[1]
  value        = each.value.value
  env_slug     = infisical_project_environment.demo.slug
  folder_path  = "/${each.value.folder}"
  workspace_id = infisical_project.data.id
  depends_on   = [infisical_secret_folder.consumer]
}

resource "infisical_secret" "pg_password" {
  for_each         = local.pg_targets
  name             = "PGPASSWORD"
  value_wo         = ephemeral.azurerm_key_vault_secret.role[each.key].value
  value_wo_version = var.password_version
  env_slug         = infisical_project_environment.demo.slug
  folder_path      = "/${each.key}"
  workspace_id     = infisical_project.data.id
  depends_on       = [infisical_secret_folder.consumer]
}

# ------------------------------------------------- identities (Kubernetes auth)

resource "infisical_identity" "consumer" {
  for_each = local.consumers
  name     = "k8s-${each.value.namespace}-${each.value.sa}"
  org_id   = var.infisical_org_id
  role     = "no-access" # org-level: nothing. Project access is granted below.
}

resource "infisical_identity_kubernetes_auth" "consumer" {
  for_each    = local.consumers
  identity_id = infisical_identity.consumer[each.key].id
  # FQDN on purpose: Infisical (Node) resolves this with a plain A query that
  # ignores the pod's DNS search list, so the short "kubernetes.default.svc"
  # fails with ENOTFOUND.
  kubernetes_host               = "https://kubernetes.default.svc.cluster.local"
  kubernetes_ca_certificate     = local.cluster_ca
  token_reviewer_mode           = "api"
  token_reviewer_jwt            = kubernetes_secret_v1.token_reviewer.data["token"]
  allowed_namespaces            = [each.value.namespace]
  allowed_service_account_names = [each.value.sa]
  access_token_ttl              = 3600
  access_token_max_ttl          = 86400
}

resource "infisical_project_identity" "consumer" {
  for_each    = local.consumers
  identity_id = infisical_identity.consumer[each.key].id
  project_id  = infisical_project.data.id
  roles       = [{ role_slug = "no-access" }]
}

# Read-only on its OWN folder in demo -- the project role above grants nothing.
resource "infisical_project_identity_specific_privilege" "consumer" {
  for_each     = local.consumers
  identity_id  = infisical_identity.consumer[each.key].id
  project_slug = infisical_project.data.slug
  permission = {
    actions = ["read"]
    subject = "secrets"
    conditions = {
      environment = infisical_project_environment.demo.slug
      secret_path = "/${each.key}"
    }
  }
  depends_on = [infisical_project_identity.consumer]
}
