# Cluster-wide Let's Encrypt issuer (DNS-01 against the Azure DNS zone that
# azure-user-ingress creates). Same pattern as the blueprint's namespaced
# Issuer, lifted to a ClusterIssuer so the nonprod namespace can mint its own
# certificate without copying secrets across namespaces.

locals {
  dns_zone_id = "${azurerm_resource_group.main.id}/providers/Microsoft.Network/dnsZones/${var.domain_name}"
}

resource "azurerm_user_assigned_identity" "cert_manager" {
  name                = "${var.prefix}-cert-manager-dns"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

# cert-manager exchanges its own controller token for this identity, so the
# credential federates against the shared controller's service account.
resource "azurerm_federated_identity_credential" "cert_manager" {
  name                      = "${var.prefix}-cert-manager-federated"
  user_assigned_identity_id = azurerm_user_assigned_identity.cert_manager.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = module.aks.outputs.oidc_issuer_url
  subject                   = module.aks.cert_manager_service_account_subject
}

# Scope: this one zone, nothing else.
resource "azurerm_role_assignment" "cert_manager_dns" {
  scope                = local.dns_zone_id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.cert_manager.principal_id

  depends_on = [module.user-ingress]
}

resource "kubectl_manifest" "cluster_issuer" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = local.cluster_issuer_name }
    spec = {
      acme = merge(
        {
          server              = "https://acme-v02.api.letsencrypt.org/directory"
          privateKeySecretRef = { name = "${local.cluster_issuer_name}-account-key" }
          solvers = [{
            dns01 = {
              azureDNS = {
                subscriptionID    = var.subscription_id
                resourceGroupName = azurerm_resource_group.main.name
                hostedZoneName    = var.domain_name
                managedIdentity   = { clientID = azurerm_user_assigned_identity.cert_manager.client_id }
              }
            }
          }]
        },
        var.letsencrypt_email == null ? {} : { email = var.letsencrypt_email },
      )
    }
  })

  depends_on = [module.aks, azurerm_role_assignment.cert_manager_dns]
}
