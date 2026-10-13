terraform {
  backend "s3" {
    bucket       = "school-demo-terraform-state-513263709619-us-east-1"
    key          = "school-demo/infra/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
