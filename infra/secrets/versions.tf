terraform {
  # >= 1.11 for ephemeral resources + write-only arguments: DB passwords flow
  # Key Vault -> Infisical without being written to this root's state.
  required_version = ">= 1.11"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
    infisical = {
      source  = "Infisical/infisical"
      version = "~> 0.20"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.36"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.19"
    }
  }

  # Same state storage account as infra/platform, its own key:
  #   terraform init -backend-config=../platform/envs/demo.backend.hcl -backend-config=key=secrets.tfstate
  backend "azurerm" {
    use_azuread_auth = true
  }
}
