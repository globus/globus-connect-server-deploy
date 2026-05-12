output "config" {
  description = "The central configuration which is used in various parts of Terraform"
  value = {
    resource_prefix = local.resource_prefix
    cidr_block      = local.cidr_block
    ssm_prefix      = local.ssm_prefix

    tags         = local.tags
    tags_no_name = local.tags_no_name
  }
}

output "endpoints" {
  description = "List of endpoints and their configuration"
  value       = [for e in module.endpoint : e.config]
}


output "credential" {
  description = "Contains GCS Client Credentials"
  value       = local.credential
  sensitive   = true
}