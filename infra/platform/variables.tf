variable "subscription_id" {
  type        = string
  description = "Azure subscription to deploy into."
}

variable "prefix" {
  type        = string
  default     = "rtl"
  description = "Short name prefix for every resource. Key Vault names cap at 24 chars, so keep this under ~8."
}

variable "location" {
  type    = string
  default = "centralus"
}

variable "domain_name" {
  type        = string
  default     = "retool.maxmccann.us"
  description = "Azure DNS zone for the deployment, NS-delegated from Cloudflare (maxmccann.us). Prod Retool serves at the apex; nonprod.<domain> hangs off the same zone."
}

variable "admin_cidrs" {
  type        = list(string)
  description = "Public CIDRs allowed to reach the AKS API server and the dataset upload container. Everything else is denied."
}

variable "letsencrypt_email" {
  type        = string
  default     = null
  description = "Optional ACME contact for expiry notices."
}

# ---------- sizing ----------
# Defaults are the "demo" profile: the cheapest shape Retool will run on. The
# blueprint defaults (2x D4as_v6, GP_Standard_D2s_v3) are the "prod" profile in envs/prod.tfvars.

variable "node_vm_size" {
  type    = string
  default = "Standard_D4as_v7"
}

variable "node_min_count" {
  type    = number
  default = 1
}

variable "node_max_count" {
  type    = number
  default = 3
}

variable "retool_db_sku" {
  type    = string
  default = "B_Standard_B2s"
}

variable "data_db_sku" {
  type    = string
  default = "B_Standard_B1ms"
}

variable "data_db_storage_mb" {
  type    = number
  default = 32768
}

# ---------- Retool ----------

variable "retool_chart_version" {
  type    = string
  default = "6.12.0" # newest on charts.retool.com; GitHub main can be ahead of the published repo
}

variable "retool_image_tag_prod" {
  type        = string
  default     = "3.334.31-stable"
  description = "Prod runs the version nonprod has already been verified on. See docs/runbooks/upgrade.md."
}

variable "retool_image_tag_nonprod" {
  type        = string
  default     = "3.334.31-stable"
  description = "Bump this first; promote to retool_image_tag_prod only after the upgrade checklist passes."
}

variable "license_key_secret_path_prod" {
  type        = string
  default     = null
  description = "Key Vault secret NAME holding the prod license key (set out-of-band with az keyvault secret set). Null = Retool free tier."
}

variable "license_key_secret_path_nonprod" {
  type    = string
  default = null
}

variable "retool_size" {
  type        = string
  default     = "demo"
  description = "demo = small CPU/memory REQUESTS (limits kept) so prod+nonprod fit on 2 nodes; prod = the chart's defaults (~11 vCPU requested per release). Observed usage at idle is 1-3% CPU."
  validation {
    condition     = contains(["demo", "prod"], var.retool_size)
    error_message = "retool_size must be demo or prod."
  }
}

variable "enable_nonprod" {
  type        = bool
  default     = true
  description = "Second Retool release in its own namespace + database on the same Flexible Server. The upgrade lane."
}

variable "tags" {
  type = map(string)
  default = {
    project = "retool-azure-platform"
    owner   = "max-mccann"
    data    = "public-sources-only"
  }
}

# ---------- ingestion ----------

variable "ingest_image_tag" {
  type        = string
  default     = null
  description = "Tag from `make ingest-image`. Null = no CronJobs (the registry and namespace still exist)."
}

variable "ingest_contact" {
  type        = string
  default     = null
  description = "Contact in every request's User-Agent (SEC's fair-access policy requires one). An email or URL publishers can reach."
  validation {
    condition     = var.ingest_image_tag == null || var.ingest_contact != null
    error_message = "Set ingest_contact before enabling the ingestion CronJobs."
  }
}
