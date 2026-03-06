packer {
  required_plugins {
    amazon = {
      version = ">= 1.1.0"
      source = "github.com/hashicorp/amazon"
    }
  }
}

locals {
  uuid = split("-", uuidv4())[0]
  timestamp = formatdate("YYYYMMDDHHmmss", timestamp())

  config = {
    ami_name = "gcs-tf"
    instance_type = "t3.micro"
    volume_size = 16
    kms_key = "alias/gcs/ebs"
    ami_users = null # Only visible in the account itself
  }

  # The trailing / means it copies the contents of the directory
  data_dir = "/opt/automation"


  # From Terraform provisioned resources
  # Optionally, turn into variables.
  terraform = {
    subnet_id = "CHANGEME"
    security_group_ids = ["CHANGEME"]
    iam_instance_profile = "CHANGEME"
  }

  # Applies to the resources created by Packer
  run_tags = {
    Name = "packer-ami-${local.timestamp}"
    "ami/packer" = true
    "ami/timestamp" = local.timestamp
  }

  # Applies to the AMI
  tags = {
    "ami/packer" = true
    "ami/source_ami" = data.amazon-parameterstore.source_ami.value
    "ami/timestamp" = local.timestamp
  }
}

data "amazon-parameterstore" "source_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
  with_decryption = false
}

source "amazon-ebs" "this" {
  source_ami = data.amazon-parameterstore.source_ami.value
  ami_name = "${local.config.ami_name}.${local.timestamp}"
  skip_ami_run_tags = true
  instance_type = "t3.small"
  subnet_id = local.terraform["subnet_id"]
  security_group_ids = local.terraform["security_group_ids"]
  ssh_username = "ubuntu"
  ssh_interface = "session_manager"
  associate_public_ip_address = false # would be true if we didn't use VPC Endpoints
  ssh_agent_auth = false # must be false for packer to successfully connect via SSM
  communicator = "ssh"
  pause_before_ssm = "1m" # slight delay to account for network delays
  iam_instance_profile = local.terraform.iam_instance_profile
  encrypt_boot =  null
  kms_key_id = null

  metadata_options {
    http_endpoint = "enabled"
    http_tokens = "required"
    http_put_response_hop_limit = 1
  }

  # Use the root volume (sda1; which is from the source AMI) and expand it if needed
  launch_block_device_mappings {
    device_name = "/dev/sda1"
    volume_size = local.config.volume_size
    volume_type = "gp3"
    delete_on_termination = true
    encrypted = true
    # Having this here and not in the main config is more efficient and prevents
    # copying the built AMI to the same region.
    kms_key_id = local.config.kms_key
  }

  # It can take some time for the AMI to be ready so we will check over the course of 45m
  # If it takes too long we will see a ResourceNotReady error:
  # https://www.packer.io/docs/builders/amazon.html#resourcenotready-error
  aws_polling {
    max_attempts  = 90 # how many times to resend a status update request
    delay_seconds = 30 # seconds to wait between status update requests
  }

  # This AMI is not shared outside of this account
  ami_users = null

  run_tags = local.run_tags
  tags = local.tags
}


build {
  name = "this"
  sources = ["source.amazon-ebs.this"]

  # The destination must be accessible to the user
  provisioner "shell" {
    inline = [
      "sudo mkdir -vp ${local.data_dir}/gcs/",
      "sudo chown -cR $(id -u):$(id -g) ${local.data_dir}/"
    ]
  }

  # Upload the tools directory contents
  # Ending slash is needed in destination
  provisioner "file" {
    source = "tools/"
    destination = "${local.data_dir}/gcs/"
  }

  provisioner "shell" {
    inline = [
      "chmod -cR 0774 ${local.data_dir}/gcs/",
    ]
  }

  provisioner "file" {
    source = "./ami-build.sh"
    destination = "/tmp/ami-build.sh"
  }

  provisioner "shell" {
    inline = [
      "chmod -v 0777 /tmp/ami-build.sh",
      "sudo su -c /tmp/ami-build.sh"
    ]
  }
}
