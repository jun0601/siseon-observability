output "athena_workgroup_name" {
  value = module.iot_pipeline.athena_workgroup_name
}

output "athena_database_name" {
  value = module.iot_pipeline.athena_database_name
}

output "query_result_bucket" {
  value = module.iot_pipeline.query_result_bucket
}