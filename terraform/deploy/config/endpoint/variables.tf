variable "endpoint" {
  description = "Endpoint configuration object"
  type = object({
    id              = string
    name            = string
    subscription_id = string
    arguments = object({
      contact-email = string
      organization  = string
      owner         = string
      department    = optional(string)
      description   = optional(string)
      info-link     = optional(string)
      keywords      = optional(string)
      project-id    = optional(string)
    })
    collection = object({
      posix = list(object({
        name         = string
        gateway_name = string
        base_path    = optional(string, "/")
      }))
    })
    gateways = list(object({
      name   = string
      domain = string
      type   = string
      restrict_paths = object({
        DATA_TYPE  = string
        read_write = optional(list(string))
        read       = optional(list(string))
        none       = optional(list(string))
      })
    }))
    role = optional(object({
      administrator    = optional(list(string), [])
      activity_monitor = optional(list(string), [])
      activity_manager = optional(list(string), [])
    }), {})
  })

  validation {
    condition     = can(regex("^[a-z0-9A-Z-]+$", var.endpoint.id))
    error_message = "ID is used for AWS resources and can only contain alphanumeric and hyphen characters"
  }

  validation {
    # For demonstration purposes, only Posix is supported. However, we account for possible expansion in our validation to make it easy in the future.
    condition     = alltrue([for gw in var.endpoint.gateways : contains(["posix"], gw.type)])
    error_message = "Gateway type must be one of: posix"
  }

  validation {
    # Email regex is quite complex; we'll just perform a simple check here
    condition     = var.endpoint.arguments.contact-email == null || can(regex("^[a-z.0-9]+@.*", var.endpoint.arguments.contact-email))
    error_message = "contact-email is not a valid email address"
  }

  validation {
    condition     = var.endpoint.arguments.info-link == null || can(regex("^http(s)://", var.endpoint.arguments.info-link))
    error_message = "info-link must start with http(s)://"
  }

  validation {
    condition     = var.endpoint.arguments.keywords == null || can(regex("^([a-z0-9A-Z-]+,?){1,}[a-z0-9A-Z-]$", var.endpoint.arguments.keywords))
    error_message = "keywords can only be a CSV of alphanumeric and hyphen characters"
  }
}