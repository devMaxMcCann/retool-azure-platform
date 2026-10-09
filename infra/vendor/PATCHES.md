# Vendored modules

Retool's blueprint repository publishes no licence, so its module code is not
stored here. `make vendor` (`vendor_modules.py`) downloads the exact release
Terraform resolves for 0.5.2 (`tryretool/terraform-retool-self-hosted-blueprints`
@ `27e541f`), copies `azure-vnet` and `azure-user-ingress` into this folder
(gitignored), and applies the patches below. Each patch is anchored; if
upstream changes an anchor, the script stops rather than patching blind.

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

## azure-user-ingress (tryretool/self-hosted-blueprints 0.5.2)

1. New input `extra_watch_namespaces`, joined into AGIC's `watchNamespace`
   (comma-separated is supported by AGIC). Upstream hard-codes the one Retool
   namespace because it assumes one App Gateway per deployment; following that
   for nonprod would add a second gateway (~$180/mo fixed). Found when the
   nonprod Ingress was never reconciled.
2. `azurerm_application_gateway.main` also ignores
   `tags["managed-by-k8s-ingress"]`, which AGIC writes on every sync and
   Terraform otherwise tries to remove on every plan.

3. AGIC's `kubernetes.ingressClass` set to `azure/<class>`, the same string as
   `ingressClassResource.controllerValue`. AGIC 1.9.7 replaces its controller
   name with INGRESS_CLASS when that is set
   (`pkg/environment/environment.go`), then only claims Ingresses whose
   IngressClass `spec.controller` equals it. Upstream sets `<class>` vs
   `azure/<class>`, so AGIC claimed nothing and the gateway served only its
   default 502 pool. Proved live (ConfigMap edit -> both pools + 443 listeners
   appeared) before patching. Changing controllerValue instead would recreate
   the IngressClass (spec.controller is immutable).

Upgrading the blueprint: diff the new release's azure-vnet against this copy,
re-apply both patches, or drop the vendor copy if upstream fixed them.
Upstream report: TODO (open an issue on tryretool/terraform-retool-self-hosted-blueprints).
