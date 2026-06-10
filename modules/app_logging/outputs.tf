output "fluentbit_role_arn" {
  value = aws_iam_role.fluentbit.arn
}

output "log_groups" {
  value = [
    aws_cloudwatch_log_group.api.name,
    aws_cloudwatch_log_group.ai.name
  ]
}