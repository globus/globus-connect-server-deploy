output "kms_key_id" {
  description = "KMS Key for Client Secrets"
  value       = aws_kms_key.ssm.key_id
}

output "ec2" {
  description = "Values referenced by EC2 Instances"
  value = {
    public_subnet_id     = aws_subnet.public.id
    iam_instance_profile = aws_iam_role.endpoint.id
    security_group_id    = aws_security_group.this.id
  }
}

output "packer" {
  description = "Values referenced by Packer"
  value = {
    subnet           = aws_subnet.private.id
    security_group   = aws_security_group.this.id
    instance_profile = aws_iam_role.packer_instance.name
    kms_key_alias    = aws_kms_alias.ebs.name
  }
}