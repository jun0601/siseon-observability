# Athena 쿼리 결과 저장 버킷
resource "aws_s3_bucket" "query_results" {
  bucket        = var.query_result_bucket
  force_destroy = true
}

# Athena 워크그룹
resource "aws_athena_workgroup" "sensor" {
  name = var.athena_workgroup_name

  configuration {
    result_configuration {
      output_location = "s3://${aws_s3_bucket.query_results.bucket}/results/"
    }
  }
}

# Glue 카탈로그 데이터베이스
resource "aws_glue_catalog_database" "sensor" {
  name = var.athena_database_name
}

# Glue 카탈로그 테이블 (Athena 외부 테이블)
resource "aws_glue_catalog_table" "sensor_data" {
  name          = "sensor_data"
  database_name = aws_glue_catalog_database.sensor.name

  table_type = "EXTERNAL_TABLE"

  parameters = {
    "classification"         = "json"
    "projection.enabled"     = "true"
    "projection.year.type"   = "integer"
    "projection.year.range"  = "2026,2030"
    "projection.month.type"  = "integer"
    "projection.month.range" = "1,12"
    "projection.month.digits" = "2"
    "projection.day.type"    = "integer"
    "projection.day.range"   = "1,31"
    "projection.day.digits"  = "2"
    "storage.location.template" = "s3://${var.sensor_bucket_name}/sensors/year=$${year}/month=$${month}/day=$${day}/"
  }

  storage_descriptor {
    location      = "s3://${var.sensor_bucket_name}/sensors/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
    }

    columns {
      name = "site_id"
      type = "string"
    }
    columns {
      name = "sensor_id"
      type = "string"
    }
    columns {
      name = "sensor_type"
      type = "string"
    }
    columns {
      name = "value_kind"
      type = "string"
    }
    columns {
      name = "value"
      type = "double"
    }
    columns {
      name = "unit"
      type = "string"
    }
    columns {
      name = "status"
      type = "string"
    }
    columns {
      name = "timestamp"
      type = "string"
    }
    columns {
      name = "sequence_id"
      type = "bigint"
    }
    columns {
      name = "schema_version"
      type = "string"
    }
    columns {
      name = "mqtt_topic"
      type = "string"
    }
  }

  partition_keys {
    name = "year"
    type = "string"
  }
  partition_keys {
    name = "month"
    type = "string"
  }
  partition_keys {
    name = "day"
    type = "string"
  }
}