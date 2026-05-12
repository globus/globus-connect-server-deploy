################
# Basic
################

locals {
  unique          = "GCS-Terraform-Demo-${formatdate("YYYYMMDDhhmmss", time_static.timestamp.rfc3339)}"
  project_id      = null
  subscription_id = null
  credential = {
    secret = "-"
    id     = "-"
  }

  resource_prefix = local.unique

  ssm_prefix = "/automation/gcs"

  cidr_block = "172.172.0.0/16"
}

################
# Endpoints
################

locals {
  argument_flags = {
    "contact-email" = "--contact-email"
    "department"    = "--department"
    "description"   = "--description"
    "info-link"     = "--info-link"
    "keywords"      = "--keywords"
    "organization"  = "--organization"
    "owner"         = "--owner"
    "project-id"    = "--project-id"
  }

  required_arguments = {
    owner         = "${local.credential.id}@clients.auth.globus.org",
    contact-email = "support@example.com",
    organization  = "Example"
  }

  # Optional but arguments that all the endpoints will have in common
  endpoint_shared_arguments = merge(
    local.required_arguments,
    {
      visibility = "--public",
      department = "Example",
      info-link  = "https://example.com",
      keywords   = "gcs-tf-demo,globus-terraform-demo,terraform-demo"
    },
    local.project_id != null ? { project-id = local.project_id } : {}
  )

  # All of our endpoints will have an identitical gateway and single POSIX collection.
  # Thus, they're defined here and will simply be referenced in the endpoint definition.
  # However, it should be relatively easy to tweak as the endpoints start to differ.
  gateways = [
    {
      name   = "main"
      domain = "CHANGEME"
      type   = "posix"
      restrict_paths = {
        DATA_TYPE  = "path_restrictions#1.0.0"
        read_write = ["~"]
        read       = ["/home/share", "/home/not shareable"]
        none       = ["/"]
      }
    }
  ]

  collection = {
    posix = [
      {
        name         = "main-posix"
        gateway_name = "main"
      }
    ]
  }

  endpoint_definitions = [
    {
      name       = "${local.unique} EP1"
      id         = "demo-ep1"
      gateways   = local.gateways
      collection = local.collection
      arguments = merge(
        local.endpoint_shared_arguments,
        {
          description = "Managed by the GCS Terraform Demo"
        }
      )
      role = {
        administrator = [] # CHANGEME: optionally add your user here
      }
    }
  ]
}

# Use a module to enforce the fields expected in the endpoint object and
# provides a means of validation and standardization. 
module "endpoint" {
  source = "./endpoint"

  for_each = {
    for e in local.endpoint_definitions : e.id => e
  }

  endpoint = {
    id              = each.value.id
    name            = each.value.name
    subscription_id = local.subscription_id
    arguments       = each.value.arguments
    gateways        = each.value.gateways
    collection      = each.value.collection
    role            = try(each.value.role, {})
  }
}

################
# Tags
################

locals {
  tags = {
    Name        = local.unique
    terraform   = true
    project     = local.unique
    gcs_version = 5
  }

  # For resources that don't use a Name tag
  tags_no_name = { for i, v in local.tags : i => v if i != "Name" }
}


resource "time_static" "timestamp" {}
