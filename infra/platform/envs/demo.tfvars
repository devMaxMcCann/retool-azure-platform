# Cheapest shape Retool runs on. Stop between demos: `make stop`.
# subscription_id and admin_cidrs come from envs/local.auto.tfvars (gitignored).
node_vm_size       = "Standard_D4as_v7"
node_min_count     = 1
node_max_count     = 3
retool_db_sku      = "B_Standard_B2s"
data_db_sku        = "B_Standard_B1ms"
data_db_storage_mb = 32768
enable_nonprod     = true
