# Ingestion lane: the registry its images come from and the namespace its
# CronJobs run in.
#
# Images are built in Azure with `make ingest-image` (az acr build), so nothing
# depends on a local Docker daemon. Nodes pull with the kubelet identity
# (AcrPull) -- no registry password exists anywhere.
#
# Database credentials do NOT come from Key Vault here. They reach the ingest
# namespace through Infisical (infra/secrets), which is the app-secrets layer;
# Key Vault stays the root of trust for what must exist before Infisical does.

resource "random_string" "acr_suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_container_registry" "main" {
  # Globally unique, alphanumeric only.
  name                = "${var.prefix}acr${random_string.acr_suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  sku                 = "Basic" # ~$5/month; no geo-replication or private endpoint needed for a demo
  admin_enabled       = false
  tags                = var.tags
}

resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = module.aks.outputs.kubelet_identity_object_id
}

resource "kubernetes_namespace_v1" "ingest" {
  metadata {
    name = "ingest"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
  depends_on = [module.aks]
}

# The identity Infisical's Kubernetes auth recognises for this namespace. The
# InfisicalSecret CR (infra/secrets) logs in as this service account.
resource "kubernetes_service_account_v1" "ingest" {
  metadata {
    name      = "ingest"
    namespace = kubernetes_namespace_v1.ingest.metadata[0].name
  }
  automount_service_account_token = false
}

# ------------------------------------------------------------------ CronJobs
# One CronJob per step, so a slow or blocked source never holds up another,
# and each has its own schedule and memory limit. Times are UTC, staggered;
# analytics runs after the daily loaders.
#
# Off until var.ingest_image_tag is set (build with `make ingest-image`).
# Credentials come from the Secrets the Infisical operator syncs (infra/secrets):
# loaders use pg-ingest (ingest_loader), analytics uses pg-analytics.

locals {
  ingest_steps = {
    warn             = { schedule = "0 10 * * *", mem = "256Mi", secret = "pg-ingest", sa = "ingest" }
    geocode          = { schedule = "30 10 * * *", mem = "256Mi", secret = "pg-ingest", sa = "ingest" }
    chicago-licenses = { schedule = "0 11 * * *", mem = "512Mi", secret = "pg-ingest", sa = "ingest" }
    idfpr-licenses   = { schedule = "30 11 * * 0", mem = "768Mi", secret = "pg-ingest", sa = "ingest" }
    bls-series       = { schedule = "0 12 * * 1", mem = "256Mi", secret = "pg-ingest", sa = "ingest" }
    bls-qcew         = { schedule = "15 12 * * 1", mem = "256Mi", secret = "pg-ingest", sa = "ingest" }
    # The bulk federal files: ~0.1-0.5 GB each, published quarterly or less.
    dol-lca         = { schedule = "0 6 1 * *", mem = "1536Mi", secret = "pg-ingest", sa = "ingest", scratch = "2Gi" }
    dol-perm        = { schedule = "0 6 2 * *", mem = "1536Mi", secret = "pg-ingest", sa = "ingest", scratch = "2Gi" }
    msha-violations = { schedule = "0 6 3 * *", mem = "1Gi", secret = "pg-ingest", sa = "ingest", scratch = "2Gi" }
    sba-ppp         = { schedule = "0 6 4 * *", mem = "1536Mi", secret = "pg-ingest", sa = "ingest", scratch = "2Gi" }
    # OSHA refuses every non-browser client (CloudFront 403, robots.txt
    # included). Suspended rather than deleted, so the decision stays visible.
    osha-sir  = { schedule = "0 6 5 * *", mem = "512Mi", secret = "pg-ingest", sa = "ingest", scratch = "1Gi", suspend = true }
    analytics = { schedule = "0 13 * * *", mem = "512Mi", secret = "pg-analytics", sa = "analytics" }
  }
  ingest_image = var.ingest_image_tag == null ? null : "${azurerm_container_registry.main.login_server}/ingest:${var.ingest_image_tag}"
}

resource "kubernetes_cron_job_v1" "ingest" {
  for_each = var.ingest_image_tag == null ? {} : local.ingest_steps

  metadata {
    name      = each.key
    namespace = kubernetes_namespace_v1.ingest.metadata[0].name
    labels    = { "app.kubernetes.io/part-of" = "ingest" }
  }
  spec {
    schedule                      = each.value.schedule
    suspend                       = lookup(each.value, "suspend", false)
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        active_deadline_seconds    = 3600
        ttl_seconds_after_finished = 604800
        template {
          metadata { labels = { "app.kubernetes.io/name" = each.key } }
          spec {
            service_account_name            = each.value.sa
            automount_service_account_token = false
            restart_policy                  = "Never"
            security_context {
              run_as_non_root = true
              run_as_user     = 10001
              seccomp_profile { type = "RuntimeDefault" }
            }
            # Idempotent; keeps jobs_ingest's tables and source_catalog current
            # with the image, so no separate migration step exists to forget.
            dynamic "init_container" {
              for_each = each.value.sa == "ingest" ? [1] : []
              content {
                name  = "schema"
                image = local.ingest_image
                args  = ["schema"]
                env_from {
                  secret_ref { name = each.value.secret }
                }
                env {
                  name  = "INGEST_CONTACT"
                  value = var.ingest_contact
                }
                resources {
                  requests = { cpu = "50m", memory = "64Mi" }
                  limits   = { memory = "128Mi" }
                }
                security_context {
                  allow_privilege_escalation = false
                  read_only_root_filesystem  = true
                  capabilities { drop = ["ALL"] }
                }
              }
            }
            container {
              name  = "step"
              image = local.ingest_image
              args  = [replace(each.key, "-", "_")]
              env_from {
                secret_ref { name = each.value.secret }
              }
              env {
                name  = "INGEST_CONTACT"
                value = var.ingest_contact
              }
              env {
                name  = "SCRATCH_DIR"
                value = "/scratch"
              }
              resources {
                requests = { cpu = "100m", memory = each.value.mem }
                limits   = { memory = each.value.mem }
              }
              security_context {
                allow_privilege_escalation = false
                read_only_root_filesystem  = true
                capabilities { drop = ["ALL"] }
              }
              volume_mount {
                name       = "scratch"
                mount_path = "/scratch"
              }
              volume_mount {
                name       = "tmp"
                mount_path = "/tmp"
              }
            }
            volume {
              name = "scratch"
              empty_dir { size_limit = lookup(each.value, "scratch", "256Mi") }
            }
            volume {
              name = "tmp"
              empty_dir { size_limit = "64Mi" }
            }
          }
        }
      }
    }
  }
}
