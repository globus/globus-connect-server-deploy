terraform {
  backend "s3" {
    bucket       = "CHANGEME"
    key          = "terraform/gcs-tf/config/terraform.tfstate"
    use_lockfile = true
  }
}