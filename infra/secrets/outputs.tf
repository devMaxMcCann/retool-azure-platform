output "project_slug" {
  value = infisical_project.data.slug
}

output "synced_secrets" {
  description = "Native Kubernetes Secrets the operator keeps in sync."
  value       = { for k, v in local.consumers : k => "${v.namespace}/pg-${k}" }
}
