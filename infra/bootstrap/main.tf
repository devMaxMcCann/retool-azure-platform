# One-time: the storage account that holds Terraform state for infra/platform.
# Local state (this root only), applied once by hand. Shared-key access is
# disabled; Terraform reaches state with Entra ID (use_azuread_auth).

terraform {
  required_version = ">= 1.11"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 5.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

variable "subscription_id" { type = string }
variable "location" {
  type    = string
  default = "centralus"
}
variable "admin_cidrs" {
  type        = list(string)
  description = "Public CIDRs allowed to reach the state account."
}

provider "azurerm" {
  features {}
  subscription_id     = var.subscription_id
  storage_use_azuread = true
}

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_resource_group" "state" {
  name     = "rtl-tfstate"
  location = var.location
}

resource "azurerm_storage_account" "state" {
  name                            = "rtltfstate${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.state.name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  public_network_access           = "Enabled"

  network_rules {
    default_action = "Deny"
    ip_rules       = [for c in var.admin_cidrs : trimsuffix(c, "/32")]
    bypass         = ["AzureServices"]
  }

  blob_properties {
    versioning_enabled = true
    delete_retention_policy { days = 14 }
  }
}

resource "azurerm_storage_container" "state" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "me" {
  scope                = azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = data.azurerm_client_config.current.object_id
}

output "backend_config" {
  value = <<-EOT
    resource_group_name  = "${azurerm_resource_group.state.name}"
    storage_account_name = "${azurerm_storage_account.state.name}"
    container_name       = "tfstate"
    key                  = "platform.tfstate"
  EOT
}
