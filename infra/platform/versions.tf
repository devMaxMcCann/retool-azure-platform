terraform {
  # >= 1.11 for write-only secret arguments (value_wo), which Retool's Azure
  # modules use to keep generated passwords out of state.
  required_version = ">= 1.11"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.36"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.19"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state lives in the storage account created by ../bootstrap.
  # Values come from `terraform init -backend-config=envs/<env>.backend.hcl`.
  backend "azurerm" {
    use_azuread_auth = true
  }
}
