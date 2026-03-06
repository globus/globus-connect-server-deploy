data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy" "SSMManaged" {
  name = "AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role" "packer_instance" {
  name               = "${local.config.resource_prefix}-packer-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_instance_profile" "packer_instance" {
  name = "${local.config.resource_prefix}-packer-instance"
  role = aws_iam_role.packer_instance.name
}

resource "aws_iam_role_policy_attachment" "SSMManaged" {
  policy_arn = data.aws_iam_policy.SSMManaged.arn
  role       = aws_iam_role.packer_instance.name
}

data "aws_iam_policy_document" "endpoint" {
  statement {
    sid    = "SSMParams"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParametersByPath",
      "ssm:PutParameter"
    ]
    resources = ["arn:aws:ssm:us-east-1:${data.aws_caller_identity.self.account_id}:parameter${local.config.ssm_prefix}/*"]
  }

  statement {
    sid    = "UpdateTags"
    effect = "Allow"
    actions = [
      "ec2:CreateTags"
    ]
    resources = ["arn:aws:ec2:us-east-1:${data.aws_caller_identity.self.account_id}:*/*"]
    # Only allow this tag with these values
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/cleaned"
      values   = ["true", "false"]
    }
    # No other tag can be in the request
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = ["cleaned"]
    }
    # Only instances that have this tag
    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/project"
      values   = [local.config.resource_prefix]
    }
  }

  statement {
    sid    = "KMSWithSSMParams"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:Encrypt"
    ]
    resources = [aws_kms_key.ssm.arn]
  }

}

resource "aws_iam_role" "endpoint" {
  name               = "${local.config.resource_prefix}-endpoint"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_policy" "endpoint" {
  name        = local.config.resource_prefix
  description = "Allows the EC2 instance to SSM Parameters"
  policy      = data.aws_iam_policy_document.endpoint.json
}

resource "aws_iam_role_policy_attachment" "endpoint" {
  policy_arn = aws_iam_policy.endpoint.arn
  role       = aws_iam_role.endpoint.name
}

resource "aws_iam_role_policy_attachment" "ecs_instance_role_policy_to_use_ssm" {
  policy_arn = data.aws_iam_policy.SSMManaged.arn
  role       = aws_iam_role.endpoint.name
}

resource "aws_iam_instance_profile" "endpoint" {
  name = "${local.config.resource_prefix}-endpoint"
  role = aws_iam_role.endpoint.name
}
