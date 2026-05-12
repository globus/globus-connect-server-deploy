terraform {
  backend "s3" {
    bucket       = "CHANGEME"
    key          = "terraform/gcs-tf/endpoints/terraform.tfstate"
    use_lockfile = true
  }
}