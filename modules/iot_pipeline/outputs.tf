output "athena_workgroup_name" {
  value = aws_athena_workgroup.sensor.name
}

output "athena_database_name" {
  value = aws_glue_catalog_database.sensor.name
}

output "query_result_bucket" {
  value = aws_s3_bucket.query_results.bucket
}