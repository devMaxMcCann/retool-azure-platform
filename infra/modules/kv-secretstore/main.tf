# A namespace + its own managed identity + a namespaced ESO SecretStore that
# can read Key Vault. Same pattern Retool's azure-retool-services uses for the
# retool namespace, factored out so every other namespace (infisical, data,
# retool-nonprod) gets its OWN identity instead of sharing one.

terraform {
  required_providers {
    azurerm    = { source = "hashicorp/azurerm" }
    kubernetes = { source = "hashicorp/kubernetes" }
    kubectl    = { source = "gavinbunney/kubectl" }
  }
}

variable "name" { type = string }
variable "prefix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "key_vault_id" { type = string }
variable "key_vault_uri" { type = string }
variable "oidc_issuer_url" { type = string }
variable "create_namespace" {
  type    = bool
  default = true
}
variable "labels" {
  type    = map(string)
  default = {}
}
variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  sa_name    = "${var.name}-kv-reader"
  store_name = "${var.name}-keyvault"
}

data "azurerm_client_config" "current" {}

resource "kubernetes_namespace_v1" "this" {
  count = var.create_namespace ? 1 : 0
  metadata {
    name = var.name
    labels = merge({
      # Restricted Pod Security on every namespace this repo owns.
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }, var.labels)
  }
}

resource "azurerm_user_assigned_identity" "this" {
  name                = "${var.prefix}-${var.name}-kv-identity"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "this" {
  name                      = "${var.prefix}-${var.name}-kv-federated"
  user_assigned_identity_id = azurerm_user_assigned_identity.this.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = var.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.name}:${local.sa_name}"
}

resource "azurerm_key_vault_access_policy" "this" {
  key_vault_id       = var.key_vault_id
  tenant_id          = data.azurerm_client_config.current.tenant_id
  object_id          = azurerm_user_assigned_identity.this.principal_id
  secret_permissions = ["Get"]
}

resource "kubernetes_service_account_v1" "this" {
  metadata {
    name      = local.sa_name
    namespace = var.name
    annotations = {
      "azure.workload.identity/client-id" = azurerm_user_assigned_identity.this.client_id
    }
  }
  automount_service_account_token = false
  depends_on                      = [kubernetes_namespace_v1.this]
}

resource "kubectl_manifest" "store" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "SecretStore"
    metadata   = { name = local.store_name, namespace = var.name }
    spec = {
      provider = {
        azurekv = {
          authType          = "WorkloadIdentity"
          tenantId          = data.azurerm_client_config.current.tenant_id
          vaultUrl          = var.key_vault_uri
          serviceAccountRef = { name = local.sa_name }
        }
      }
    }
  })
  depends_on = [kubernetes_service_account_v1.this, azurerm_key_vault_access_policy.this]
}

output "namespace" { value = var.name }
output "secret_store_name" { value = local.store_name }
output "identity_client_id" { value = azurerm_user_assigned_identity.this.client_id }
output "identity_principal_id" { value = azurerm_user_assigned_identity.this.principal_id }
