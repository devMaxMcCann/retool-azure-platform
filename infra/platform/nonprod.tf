# Nonprod Retool: same cluster, own namespace, own Key Vault secrets and ESO
# identity, own database (retool_nonprod on the main Flexible Server), served
# at nonprod.<domain> through the same Application Gateway.
#
# This is the upgrade lane: bump retool_image_tag_nonprod / retool_chart_version
# here first, run docs/runbooks/upgrade.md, then promote the tag to prod.

locals {
  nonprod_domain = "nonprod.${var.domain_name}"
}

module "retool-services-nonprod" {
  count   = var.enable_nonprod ? 1 : 0
  source  = "tryretool/self-hosted-blueprints/retool//modules/azure-retool-services"
  version = "~> 0.5"

  prefix              = "${var.prefix}-np"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  vnet                = module.vnet.outputs
  aks                 = module.aks.outputs
  db                  = merge(module.db-main.outputs, { name = "retool_nonprod" })

  retool_namespace        = "retool-nonprod"
  license_key_secret_path = var.license_key_secret_path_nonprod
  tags                    = var.tags
}

resource "kubectl_manifest" "nonprod_certificate" {
  count = var.enable_nonprod ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata   = { name = "nonprod-tls", namespace = "retool-nonprod" }
    spec = {
      secretName = "nonprod-tls"
      issuerRef  = { name = local.cluster_issuer_name, kind = "ClusterIssuer" }
      dnsNames   = [local.nonprod_domain]
    }
  })

  depends_on = [module.retool-services-nonprod, kubectl_manifest.cluster_issuer]
}

module "retool-nonprod" {
  count   = var.enable_nonprod ? 1 : 0
  source  = "tryretool/self-hosted-blueprints/retool//modules/retool-helm"
  version = "~> 0.5"

  retool_helm_name          = "retool-nonprod"
  retool_helm_chart_version = var.retool_chart_version

  db              = merge(module.db-main.outputs, { name = "retool_nonprod" })
  retool_services = module.retool-services-nonprod[0].outputs
  user_ingress = merge(module.user-ingress.outputs, {
    tls_secret_name     = "nonprod-tls"
    cluster_issuer_name = local.cluster_issuer_name
    issuer_kind         = "ClusterIssuer"
  })
  domain_name   = local.nonprod_domain
  https_enabled = true

  retool_helm_extra_values = [yamlencode({
    image = { tag = var.retool_image_tag_nonprod }
    ingress = {
      annotations = {
        # Evaluated before prod's *.<domain> wildcard listener (priority 1000).
        "appgw.ingress.kubernetes.io/rule-priority" = "900"
        # No wildcard alias for nonprod.
        "appgw.ingress.kubernetes.io/hostname-extension" = local.nonprod_domain
      }
      tls = [{ secretName = "nonprod-tls", hosts = [local.nonprod_domain] }]
    }
    # Smaller footprint than prod: nonprod is for verifying upgrades, not load.
    replicaCount = 1
  })]

  depends_on = [module.retool, kubectl_manifest.nonprod_certificate, azurerm_postgresql_flexible_server_database.main_extra]
}
