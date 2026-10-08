# Cluster side of Infisical's Kubernetes auth.
#
# Infisical checks a pod's service-account JWT by calling the TokenReview API.
# It needs its own long-lived token to do that, bound to system:auth-delegator
# (which can create TokenReviews and nothing else).

data "kubernetes_config_map_v1" "kube_root_ca" {
  metadata {
    name      = "kube-root-ca.crt"
    namespace = "default"
  }
}

locals {
  cluster_ca = data.kubernetes_config_map_v1.kube_root_ca.data["ca.crt"]
}

resource "kubernetes_service_account_v1" "token_reviewer" {
  metadata {
    name      = "infisical-token-reviewer"
    namespace = "infisical"
  }
}

resource "kubernetes_cluster_role_binding_v1" "token_reviewer" {
  metadata { name = "infisical-token-reviewer" }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:auth-delegator"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.token_reviewer.metadata[0].name
    namespace = "infisical"
  }
}

resource "kubernetes_secret_v1" "token_reviewer" {
  metadata {
    name      = "infisical-token-reviewer"
    namespace = "infisical"
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.token_reviewer.metadata[0].name
    }
  }
  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

# ------------------------------------------------ consumer service accounts

# infra/platform creates the `ingest` namespace and its `ingest` SA. The
# analytics builder gets its own SA so it authenticates as a different
# identity and can read only /analytics.
resource "kubernetes_service_account_v1" "analytics" {
  metadata {
    name      = "analytics"
    namespace = "ingest"
  }
  automount_service_account_token = false
}

# One InfisicalSecret per consumer -> a native Secret named pg-<consumer>.
resource "kubectl_manifest" "infisical_secret" {
  for_each = local.consumers
  yaml_body = yamlencode({
    apiVersion = "secrets.infisical.com/v1alpha1"
    kind       = "InfisicalSecret"
    metadata   = { name = "pg-${each.key}", namespace = each.value.namespace }
    spec = {
      hostAPI        = "http://infisical-infisical-standalone-infisical.infisical.svc.cluster.local:8080/api"
      resyncInterval = 300
      authentication = {
        kubernetesAuth = {
          identityId                    = infisical_identity.consumer[each.key].id
          autoCreateServiceAccountToken = true
          serviceAccountRef             = { name = each.value.sa, namespace = each.value.namespace }
          secretsScope = {
            projectSlug = infisical_project.data.slug
            envSlug     = infisical_project_environment.demo.slug
            secretsPath = "/${each.key}"
          }
        }
      }
      managedKubeSecretReferences = [{
        secretName      = "pg-${each.key}"
        secretNamespace = each.value.namespace
        creationPolicy  = "Owner"
      }]
    }
  })
  depends_on = [
    infisical_project_identity_specific_privilege.consumer,
    infisical_identity_kubernetes_auth.consumer,
    kubernetes_service_account_v1.analytics,
  ]
}
