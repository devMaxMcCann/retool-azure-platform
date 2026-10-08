# Self-hosted Infisical: the secrets manager apps and pipelines use to share
# credentials (data-DB roles, Retool API token, Azure DevOps PAT, ...).
#
# Trust layering:
#   Key Vault  = root of trust. Holds only what must exist BEFORE Infisical
#                does: Infisical's own encryption/auth keys, DB admin creds,
#                and Retool's encryption key/JWT (Retool's modules read KV).
#   Infisical  = everything app-to-app, with per-namespace machine identities
#                (Kubernetes auth) and audit logs. Configured by infra/secrets.
#
# Private by design: ClusterIP only, no Ingress. Admin access is
# `make infisical-ui` (kubectl port-forward), which already requires passing
# the AKS API allowlist.

resource "random_bytes" "infisical_encryption_key" {
  length = 16 # Infisical wants 32 hex chars
}

resource "random_bytes" "infisical_auth_secret" {
  length = 32
}

resource "random_password" "infisical_redis" {
  length  = 32
  special = false
}

resource "azurerm_key_vault_secret" "infisical" {
  for_each = {
    "infisical-encryption-key" = random_bytes.infisical_encryption_key.hex
    "infisical-auth-secret"    = random_bytes.infisical_auth_secret.base64
    "infisical-redis-password" = random_password.infisical_redis.result
  }
  name             = each.key
  value_wo         = each.value
  value_wo_version = 1
  key_vault_id     = module.vnet.key_vault_id
}

module "ns_infisical" {
  source = "../modules/kv-secretstore"

  name                = "infisical"
  prefix              = var.prefix
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  key_vault_id        = module.vnet.key_vault_id
  key_vault_uri       = module.vnet.key_vault_uri
  oidc_issuer_url     = module.aks.outputs.oidc_issuer_url
  # Bitnami Redis subchart doesn't meet "restricted"; baseline still blocks
  # privileged/hostPath/hostNetwork.
  labels = { "pod-security.kubernetes.io/enforce" = "baseline" }
  tags   = var.tags

  depends_on = [module.aks]
}

# The chart reads every Infisical setting from this one Secret (kubeSecretRef).
resource "kubectl_manifest" "infisical_secrets" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata   = { name = "infisical-secrets", namespace = module.ns_infisical.namespace }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { kind = "SecretStore", name = module.ns_infisical.secret_store_name }
      target = {
        name           = "infisical-secrets"
        creationPolicy = "Owner"
        template = {
          engineVersion = "v2"
          data = {
            ENCRYPTION_KEY    = "{{ .enc }}"
            AUTH_SECRET       = "{{ .auth }}"
            DB_CONNECTION_URI = "postgresql://infisical:{{ .dbpw }}@${module.db-main.outputs.address}:5432/infisical?sslmode=require"
            REDIS_URL         = "redis://:{{ .redispw }}@redis-master:6379"
            SITE_URL          = "http://localhost:8080"
            TELEMETRY_ENABLED = "false"
            # Kubernetes auth validates tokens against the in-cluster API (10.96.0.1);
            # Infisical's SSRF guard rejects private IPs ("Local IPs not allowed as
            # URL") without this. Acceptable: only Infisical admins configure outbound
            # targets, and Infisical has no public ingress.
            ALLOW_INTERNAL_IP_CONNECTIONS = "true"
          }
        }
      }
      data = [
        { secretKey = "enc", remoteRef = { key = "infisical-encryption-key" } },
        { secretKey = "auth", remoteRef = { key = "infisical-auth-secret" } },
        { secretKey = "dbpw", remoteRef = { key = "db-main-infisical" } },
        { secretKey = "redispw", remoteRef = { key = "infisical-redis-password" } },
      ]
    }
  })
  depends_on = [module.ns_infisical, azurerm_key_vault_secret.infisical, azurerm_key_vault_secret.db_roles]
}

resource "helm_release" "infisical" {
  name       = "infisical"
  namespace  = module.ns_infisical.namespace
  repository = "https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/"
  chart      = "infisical-standalone"
  version    = "1.11.0"
  timeout    = 900

  values = [yamlencode({
    infisical = {
      replicaCount  = 1
      kubeSecretRef = "infisical-secrets"
      image         = { tag = "v0.158.0" }
      autoBootstrap = { enabled = false } # first admin is created by hand in the UI, then stage 2 takes over
      service       = { type = "ClusterIP" }
    }
    ingress    = { enabled = false, nginx = { enabled = false } }
    postgresql = { enabled = false } # managed Flexible Server instead
    redis = {
      enabled = true
      auth    = { password = random_password.infisical_redis.result }
    }
  })]

  depends_on = [kubectl_manifest.infisical_secrets, kubernetes_job_v1.db_bootstrap]
}

# Operator that syncs InfisicalSecret CRs into native k8s Secrets, per namespace.
resource "helm_release" "infisical_operator" {
  name             = "infisical-secrets-operator"
  namespace        = "infisical-operator"
  create_namespace = true
  repository       = "https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/"
  chart            = "secrets-operator"
  version          = "0.11.11"

  depends_on = [module.aks]
}
