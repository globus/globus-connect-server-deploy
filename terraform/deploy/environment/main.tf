data "aws_ami" "gcs" {
  owners      = ["self"]
  most_recent = true

  filter {
    name   = "name"
    values = ["gcs-tf.*"]
  }
}

locals {
  config    = data.terraform_remote_state.config.outputs.config
  endpoints = data.terraform_remote_state.config.outputs.endpoints
  shared    = data.terraform_remote_state.shared.outputs
}

data "terraform_remote_state" "config" {
  backend = "s3"

  config = {
    bucket = "CHANGEME"
    key    = "terraform/gcs-tf/config/terraform.tfstate"
    region = "us-east-1"
  }
}

data "terraform_remote_state" "shared" {
  backend = "s3"

  config = {
    bucket = "CHANGEME"
    key    = "terraform/gcs-tf/shared/terraform.tfstate"
    region = "us-east-1"
  }
}

resource "aws_ssm_parameter" "endpoint" {
  for_each = { for endpoint in local.endpoints : endpoint.id => endpoint }
  name     = "${local.config.ssm_prefix}/endpoint/${each.value.id}/config"
  type     = "SecureString"
  key_id   = local.shared.kms_key_id
  value    = jsonencode(each.value)
}

resource "aws_ssm_parameter" "endpoint_id" {
  for_each = toset([for endpoint in local.endpoints : endpoint.id])
  name     = "${local.config.ssm_prefix}/endpoint/${each.key}/id"
  type     = "SecureString"
  key_id   = local.shared.kms_key_id
  value    = "-"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "deployment_key" {
  for_each = toset([for endpoint in local.endpoints : endpoint.id])
  name     = "${local.config.ssm_prefix}/endpoint/${each.key}/deployment_key"
  type     = "SecureString"
  key_id   = local.shared.kms_key_id
  value    = "-"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_instance" "this" {
  for_each                    = toset([for endpoint in local.endpoints : endpoint.id])
  ami                         = data.aws_ami.gcs.id
  instance_type               = "t3.large"
  subnet_id                   = local.shared.ec2.public_subnet_id
  vpc_security_group_ids      = [local.shared.ec2.security_group_id]
  associate_public_ip_address = true
  iam_instance_profile        = local.shared.ec2.iam_instance_profile

  root_block_device {
    delete_on_termination = true
    volume_size           = 60
    volume_type           = "gp3"
  }

  tags = merge(
    local.config.tags_no_name,
    {
      Name     = each.key
    }
  )

  # Safety check to ensure that the node was cleaned up before it's replaced
  provisioner "local-exec" {
    when    = destroy
    command = <<EOT
      ${lookup(self.tags_all, "cleaned", "false")} && exit 0
      printf "%s\n" "SSM Document node-cleanup or cleanup script needs to be ran first" && exit 1
    EOT
  }

  lifecycle {
    ignore_changes = [tags["cleaned"]]
  }
}
