locals {
  config     = data.terraform_remote_state.config.outputs.config
  credential = data.terraform_remote_state.config.outputs.credential
}

data "aws_caller_identity" "self" {}

data "terraform_remote_state" "config" {
  backend = "s3"

  config = {
    bucket = "CHANGEME"
    key    = "terraform/gcs-tf/config/terraform.tfstate"
    region = "us-east-1"
  }
}

resource "aws_kms_key" "ssm" {
  description = "GCS SSM Parameters"

  deletion_window_in_days = 7
}

resource "aws_kms_alias" "ssm" {
  name          = "alias/gcs/ssm"
  target_key_id = aws_kms_key.ssm.id
}

resource "aws_kms_key" "ebs" {
  description = "GCS EBS Volumes"

  deletion_window_in_days = 7
}

resource "aws_kms_alias" "ebs" {
  name          = "alias/gcs/ebs"
  target_key_id = aws_kms_key.ebs.id
}

resource "aws_ssm_parameter" "client" {
  for_each = local.credential
  name     = "${local.config.ssm_prefix}/client/${each.key}"
  type     = "SecureString"
  key_id   = aws_kms_key.ssm.key_id
  value    = each.value
}
