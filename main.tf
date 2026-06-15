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

module "app_logging_ohio" {
  source = "./modules/app_logging"

  providers = {
    aws        = aws.ohio
    helm       = helm.ohio
    kubernetes = kubernetes.ohio
  }

  cluster_name        = var.ohio_cluster_name
  aws_account_id      = var.aws_account_id
  eks_oidc_issuer     = local.ohio_eks_oidc_issuer
  region              = "us-east-2"
  fluentbit_role_name = "ohio-fluentbit-role"
}

locals {
  eks_oidc_issuer      = replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
  ohio_eks_oidc_issuer = replace(data.aws_eks_cluster.ohio.identity[0].oidc[0].issuer, "https://", "")
}

module "tracing" {
  source = "./modules/tracing"

  aws_account_id  = var.aws_account_id
  eks_oidc_issuer = local.eks_oidc_issuer
}