provider "aws" {
  region  = "ap-northeast-2"
  profile = "siseon"
}

module "iot_pipeline" {
  source = "./modules/iot_pipeline"

  athena_database_name  = var.athena_database_name
  athena_workgroup_name = var.athena_workgroup_name
  sensor_bucket_name    = var.sensor_bucket_name
  query_result_bucket   = var.query_result_bucket
}

module "app_logging" {
  source = "./modules/app_logging"

  cluster_name    = var.cluster_name
  aws_account_id  = var.aws_account_id
  eks_oidc_issuer = local.eks_oidc_issuer
}

locals {
  eks_oidc_issuer = replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

module "tracing" {
  source = "./modules/tracing"

  aws_account_id  = var.aws_account_id
  eks_oidc_issuer = local.eks_oidc_issuer
}