# Read-only ingestion + analytics dashboard at demo.<domain>.
#
# Reads Postgres as retool_reader (credentials synced by Infisical into
# Secret dashboard/pg-dashboard, see infra/secrets) and the Kubernetes API with
# a Role limited to get/list of Jobs, CronJobs and Pods in `ingest`.
# Image built in ACR: `make dashboard-image`, pinned by tag.

variable "dashboard_image_tag" {
  type        = string
  default     = null
  description = "Tag from `make dashboard-image`. Null = namespace/RBAC only, no Deployment."
}

locals {
  demo_domain = "demo.${var.domain_name}"
  dashboard   = var.dashboard_image_tag == null ? 0 : 1
}

resource "kubernetes_namespace_v1" "dashboard" {
  metadata {
    name = "dashboard"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

resource "kubernetes_service_account_v1" "dashboard" {
  metadata {
    name      = "dashboard"
    namespace = kubernetes_namespace_v1.dashboard.metadata[0].name
  }
  # The app reads the Kubernetes API with this token (Role below).
  automount_service_account_token = true
}

resource "kubernetes_role_v1" "dashboard_ingest_reader" {
  metadata {
    name      = "dashboard-reader"
    namespace = kubernetes_namespace_v1.ingest.metadata[0].name
  }
  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = ["get", "list"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_role_binding_v1" "dashboard_ingest_reader" {
  metadata {
    name      = "dashboard-reader"
    namespace = kubernetes_namespace_v1.ingest.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.dashboard_ingest_reader.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.dashboard.metadata[0].name
    namespace = kubernetes_namespace_v1.dashboard.metadata[0].name
  }
}

resource "kubernetes_deployment_v1" "dashboard" {
  count = local.dashboard
  metadata {
    name      = "dashboard"
    namespace = kubernetes_namespace_v1.dashboard.metadata[0].name
    labels    = { app = "dashboard" }
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "dashboard" } }
    template {
      metadata { labels = { app = "dashboard" } }
      spec {
        service_account_name = kubernetes_service_account_v1.dashboard.metadata[0].name
        security_context {
          run_as_non_root = true
          run_as_user     = 10003
          seccomp_profile { type = "RuntimeDefault" }
        }
        container {
          name  = "dashboard"
          image = "${azurerm_container_registry.main.login_server}/dashboard:${var.dashboard_image_tag}"
          port { container_port = 8080 }
          env_from {
            secret_ref { name = "pg-dashboard" }
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            period_seconds = 10
          }
          resources {
            requests = { cpu = "25m", memory = "64Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }
          # Repeated from the pod level on purpose (provider sends
          # runAsNonRoot=false otherwise; see data.tf).
          security_context {
            run_as_non_root            = true
            run_as_user                = 10003
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities { drop = ["ALL"] }
          }
        }
      }
    }
  }
  # pg-dashboard is created by the infra/secrets apply that follows; don't block
  # this apply waiting for a pod that can't start yet.
  wait_for_rollout = false
  depends_on       = [azurerm_role_assignment.aks_acr_pull]

  lifecycle {
    # Reloader stamps STAKATER_*_SECRET env vars to roll the pod when
    # pg-dashboard rotates; this container sets no env of its own.
    ignore_changes = [spec[0].template[0].spec[0].container[0].env]
  }
}

resource "kubernetes_service_v1" "dashboard" {
  count = local.dashboard
  metadata {
    name      = "dashboard"
    namespace = kubernetes_namespace_v1.dashboard.metadata[0].name
  }
  spec {
    selector = { app = "dashboard" }
    port {
      port        = 80
      target_port = 8080
    }
  }
}

resource "kubectl_manifest" "dashboard_certificate" {
  count = local.dashboard
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata   = { name = "demo-tls", namespace = "dashboard" }
    spec = {
      secretName = "demo-tls"
      issuerRef  = { name = local.cluster_issuer_name, kind = "ClusterIssuer" }
      dnsNames   = [local.demo_domain]
    }
  })
  depends_on = [kubernetes_namespace_v1.dashboard, kubectl_manifest.cluster_issuer]
}

resource "kubernetes_ingress_v1" "dashboard" {
  count = local.dashboard
  metadata {
    name      = "dashboard"
    namespace = kubernetes_namespace_v1.dashboard.metadata[0].name
    annotations = {
      # Before prod's *.<domain> wildcard listener (1000) and nonprod (900).
      "appgw.ingress.kubernetes.io/rule-priority"     = "800"
      "appgw.ingress.kubernetes.io/health-probe-path" = "/healthz"
      "appgw.ingress.kubernetes.io/ssl-redirect"      = "true"
    }
  }
  spec {
    ingress_class_name = "${var.prefix}-agic"
    tls {
      hosts       = [local.demo_domain]
      secret_name = "demo-tls"
    }
    rule {
      host = local.demo_domain
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.dashboard[0].metadata[0].name
              port { number = 80 }
            }
          }
        }
      }
    }
  }
  depends_on = [kubectl_manifest.dashboard_certificate]
}

# Explicit record: _acme-challenge.demo would otherwise shadow the wildcard
# (same RFC 4592 trap as nonprod).
resource "azurerm_dns_a_record" "demo" {
  name                = "demo"
  zone_name           = var.domain_name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  target_resource_id  = "${azurerm_resource_group.main.id}/providers/Microsoft.Network/publicIPAddresses/${var.prefix}-appgw-ip"
  tags                = var.tags
  depends_on          = [module.user-ingress]
}

output "dashboard_url" {
  value = "https://${local.demo_domain}"
}
