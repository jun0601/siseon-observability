terraform {
  backend "s3" {
    bucket  = "siseon-terraform-state"
    key     = "observability/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "siseon"
  }
}