# Vendored modules

## azure-vnet (tryretool/self-hosted-blueprints 0.5.2)

Copied verbatim from the registry release, then two `lifecycle` blocks added
(search for `PATCH (retool-azure-platform)`):

1. `azurerm_key_vault.main` ignores `access_policy`. The module declares the
   Terraform caller's policy inline, while `azure-retool-services` (and this
   repo's `kv-secretstore`) add workload-identity policies as separate
   `azurerm_key_vault_access_policy` resources. azurerm treats the inline list
   as authoritative, so the second apply removes the ESO identities' access
   and Retool's secrets stop syncing. Found in our second `terraform plan`
   (2 policies scheduled for removal).
2. `azurerm_subnet.postgres` ignores `service_endpoint`. Azure attaches
   `Microsoft.Storage` when a Flexible Server joins the delegated subnet.

Upgrading the blueprint: diff the new release's azure-vnet against this copy,
re-apply both patches, or drop the vendor copy if upstream fixed them.
Upstream report: TODO (open an issue on tryretool/terraform-retool-self-hosted-blueprints).
