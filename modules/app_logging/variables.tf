variable "cluster_name" {}
variable "aws_account_id" {}
variable "eks_oidc_issuer" {}

variable "region" {
  description = "CloudWatch 로그를 기록할 리전"
  default     = "ap-northeast-2"
}

variable "fluentbit_role_name" {
  description = "Fluent Bit IRSA 역할 이름 (IAM은 글로벌이라 리전별로 고유해야 함)"
  default     = "seoul-fluentbit-role"
}