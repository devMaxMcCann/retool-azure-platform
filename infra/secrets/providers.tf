provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

# Infisical has no Ingress (private by design), so applies run through
# `make infisical-ui` (port-forward to localhost:8080). The admin identity's
# client id/secret come from the environment, never from a file:
#   INFISICAL_UNIVERSAL_AUTH_CLIENT_ID / INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET
# (`make secrets-plan` loads them from the macOS Keychain).
provider "infisical" {
  host = var.infisical_host
  auth = {
    universal = {}
  }
}

# Your current kubectl context (`make kubeconfig` points it at the cluster).
provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = var.kube_context
}

provider "kubectl" {
  config_path      = "~/.kube/config"
  config_context   = var.kube_context
  load_config_file = true
}
