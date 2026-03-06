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

  # We need to jsonencode the restrict paths
  gateways = [
    for gateway in var.endpoint.gateways : merge(
      gateway,
      { restrict_paths = jsonencode(gateway.restrict_paths) }
    )
  ]

  # Perform overrides as needed which will then be included in the output
  endpoint = merge(
    var.endpoint,
    {
      arguments = merge(
        {
          # Fallback to the flag if there's no actual argument for it (e.g. --public)
          # The tooling will check and account for it.
          for flag, argument in var.endpoint.arguments : lookup(local.argument_flags, flag, argument) => argument
        },
        # agree-to-letsencrypt is required for automation and we enfore --public as --private can cause issues
        {
          "--agree-to-letsencrypt-tos" = "--agree-to-letsencrypt-tos",
          "--public"                   = "--public"
        }
      )
    },
    { gateways = local.gateways },
  )
}