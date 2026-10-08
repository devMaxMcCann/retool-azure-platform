output "retool_url" {
  value = "https://${var.domain_name}"
}

output "retool_nonprod_url" {
  value = var.enable_nonprod ? "https://${local.nonprod_domain}" : null
}

output "dns_zone_name_servers" {
  description = "Add these as NS records for `retool` in the maxmccann.us Cloudflare zone (DNS only, not proxied)."
  value       = module.user-ingress.outputs.zone_name_servers
}

output "ingress_public_ip" {
  value = module.user-ingress.outputs.public_ip_address
}

output "aks_name" {
  value = "${var.prefix}-aks" # module.aks.outputs is wholly sensitive (kube certs)
}

output "resource_group" {
  value = azurerm_resource_group.main.name
}

output "key_vault_name" {
  value = module.vnet.key_vault_name
}

output "data_db_host" {
  description = "Private FQDN; resolves only inside the VNet. Retool resource host."
  value       = azurerm_postgresql_flexible_server.data.fqdn
}

output "acr_login_server" {
  value = azurerm_container_registry.main.login_server
}

output "acr_name" {
  value = azurerm_container_registry.main.name
}
