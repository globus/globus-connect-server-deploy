locals {
  ssm_docs = [
    {
      name = "setup"
      path = "./setup.yaml"
    },
    {
      name = "endpoint-setup"
      path = "endpoint-setup.yaml"
    },
    {
      name = "node-setup"
      path = "node-setup.yaml"
    },
    {
      name = "node-cleanup"
      path = "node-cleanup.yaml"
    },
    {
      name = "destroy"
      path = "destroy.yaml"
    }
  ]
}

resource "aws_ssm_document" "scripts" {
  for_each        = { for _, doc in local.ssm_docs : doc.name => doc }
  name            = "${local.config.resource_prefix}-${each.value.name}"
  document_format = "YAML"
  document_type   = "Command"

  content = file("./ssm-docs/${each.value.path}")
}

resource "aws_ssm_association" "setup" {
  for_each         = { for k, v in aws_instance.this : k => v.id }
  name             = aws_ssm_document.scripts["setup"].name
  association_name = "${each.key}-auto-setup"
  # 8 minutes should be more than enough time
  wait_for_success_timeout_seconds = 480

  parameters = {
    "SSMID" = each.key
  }

  targets {
    key    = "InstanceIds"
    values = [each.value]
  }
}
