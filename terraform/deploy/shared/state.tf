terraform {
  backend "s3" {
    bucket       = "CHANGEME"
    key          = "terraform/gcs-tf/shared/terraform.tfstate"
    use_lockfile = true
  }
}