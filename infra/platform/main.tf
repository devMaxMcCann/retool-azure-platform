# Prod Retool, composed from Retool's own Azure blueprint modules
# (github.com/tryretool/terraform-retool-self-hosted-blueprints). Staying on the
# vendor-maintained modules is deliberate: chart/operator upgrades come from
# Retool, and what this repo adds (nonprod lane, public-data DB, shared TLS
# issuer) sits beside them rather than inside a fork.

locals {
  blueprint_version   = "~> 0.5"
  resource_group_name = "${var.prefix}-platform"
  cluster_issuer_name = "letsencrypt-azuredns"
}

resource "azurerm_resource_group" "main" {
  name     = local.resource_group_name
  location = var.location
  tags     = var.tags
}

module "vnet" {
  source  = "tryretool/self-hosted-blueprints/retool//modules/azure-vnet"
  version = "~> 0.5"

  prefix              = var.prefix
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  tags                = var.tags
}

module "aks" {
  source  = "tryretool/self-hosted-blueprints/retool//modules/azure-aks"
  version = "~> 0.5"

  prefix              = var.prefix
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  vnet                = module.vnet.outputs

  node_vm_size   = var.node_vm_size
  node_min_count = var.node_min_count
  node_max_count = var.node_max_count

  # API server is reachable only from admin_cidrs (the AKS equivalent of a
  # private EKS endpoint with a CIDR allowlist).
  api_server_authorized_ip_ranges = var.admin_cidrs

  tags       = var.tags
  depends_on = [module.vnet]
}

module "db-main" {
  source  = "tryretool/self-hosted-blueprints/retool//modules/azure-database"
  version = "~> 0.5"

  prefix              = var.prefix
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  db_purpose          = "main"
  vnet                = module.vnet.outputs
  sku_name            = var.retool_db_sku
  storage_mb          = 32768
  tags                = var.tags

  depends_on = [module.vnet]
}

module "retool-services" {
  source  = "tryretool/self-hosted-blueprints/retool//modules/azure-retool-services"
  version = "~> 0.5"

  prefix              = var.prefix
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  vnet                = module.vnet.outputs
  aks                 = module.aks.outputs
  db                  = module.db-main.outputs

  retool_namespace        = "retool"
  license_key_secret_path = var.license_key_secret_path_prod
  tags                    = var.tags
}

module "user-ingress" {
  source  = "tryretool/self-hosted-blueprints/retool//modules/azure-user-ingress"
  version = "~> 0.5"

  prefix              = var.prefix
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  domain_name         = var.domain_name
  vnet                = module.vnet.outputs
  aks                 = module.aks.outputs
  enable_https        = true

  # One ClusterIssuer (tls.tf) serves prod, nonprod and anything else in the
  # zone, instead of the module's per-namespace Issuer.
  cluster_issuer_name = local.cluster_issuer_name

  retool_services = module.retool-services.outputs
  tags            = var.tags

  depends_on = [module.aks, module.retool-services]
}

module "retool" {
  source  = "tryretool/self-hosted-blueprints/retool//modules/retool-helm"
  version = "~> 0.5"

  retool_helm_name          = "retool"
  retool_helm_chart_version = var.retool_chart_version

  db              = module.db-main.outputs
  retool_services = module.retool-services.outputs
  user_ingress    = module.user-ingress.outputs
  domain_name     = var.domain_name
  https_enabled   = true

  retool_helm_extra_values = [yamlencode({
    image = { tag = var.retool_image_tag_prod }
  })]

  depends_on = [module.aks, module.retool-services, module.user-ingress, kubectl_manifest.cluster_issuer]
}
