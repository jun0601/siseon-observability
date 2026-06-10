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