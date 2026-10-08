variable "subscription_id" {
  type = string
}

variable "prefix" {
  type    = string
  default = "rtl"
}

variable "key_vault_name" {
  type        = string
  description = "infra/platform output key_vault_name."
}

variable "infisical_org_id" {
  type        = string
  description = "Organization ID from Infisical's UI (Organization Settings). Not a secret."
}

variable "infisical_host" {
  type    = string
  default = "http://localhost:8080"
}

variable "kube_context" {
  type    = string
  default = "rtl-aks"
}

variable "password_version" {
  type        = number
  default     = 1
  description = "Bump after rotating the DB role passwords in Key Vault, to push the new values into Infisical."
}
