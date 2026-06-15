# ─────────────────────────────────────────────
# 1. CloudWatch Log Group (서비스별)
# ─────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/eks/${var.cluster_name}/stockops/api"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "ai" {
  name              = "/aws/eks/${var.cluster_name}/stockops/ai"
  retention_in_days = 7
}

# ─────────────────────────────────────────────
# 2. Fluent Bit IRSA Role
# ─────────────────────────────────────────────
resource "aws_iam_role" "fluentbit" {
  name = var.fluentbit_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::${var.aws_account_id}:oidc-provider/${var.eks_oidc_issuer}"
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.eks_oidc_issuer}:sub" = "system:serviceaccount:amazon-cloudwatch:fluent-bit"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "fluentbit" {
  name = "fluentbit-cloudwatch-logs"
  role = aws_iam_role.fluentbit.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
        "logs:DescribeLogGroups"
      ]
      Resource = "arn:aws:logs:${var.region}:${var.aws_account_id}:log-group:/aws/eks/${var.cluster_name}/stockops/*"
    }]
  })
}

# ─────────────────────────────────────────────
# 3. amazon-cloudwatch 네임스페이스
# ─────────────────────────────────────────────
resource "kubernetes_namespace" "cloudwatch" {
  metadata {
    name = "amazon-cloudwatch"
  }
}

# ─────────────────────────────────────────────
# 4. Fluent Bit Helm 릴리스 (DaemonSet)
# ─────────────────────────────────────────────
resource "helm_release" "fluentbit" {
  name       = "fluent-bit"
  repository = "https://fluent.github.io/helm-charts"
  chart      = "fluent-bit"
  namespace  = kubernetes_namespace.cloudwatch.metadata[0].name
  version    = "0.46.7"
  timeout    = 600

  values = [
    yamlencode({
      livenessProbe = {
        httpGet = {
          path = "/api/v1/health"
          port = 2020
        }
      }
      readinessProbe = {
        httpGet = {
          path = "/api/v1/health"
          port = 2020
        }
      }
      serviceAccount = {
        create = true
        name   = "fluent-bit"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.fluentbit.arn
        }
      }

      config = {
        service = <<-EOT
          [SERVICE]
              Daemon Off
              Flush 5
              Log_Level info
              Parsers_File /fluent-bit/etc/parsers.conf
              Parsers_File /fluent-bit/etc/conf/custom_parsers.conf
              HTTP_Server On
              HTTP_Listen 0.0.0.0
              HTTP_Port 2020
              Health_Check On
        EOT

        inputs = <<-EOT
          [INPUT]
              Name tail
              Path /var/log/containers/stockops-api*.log
              Tag stockops.api.*
              Parser docker
              Mem_Buf_Limit 10MB
              Skip_Long_Lines On

          [INPUT]
              Name tail
              Path /var/log/containers/stockops-ai*.log
              Tag stockops.ai.*
              Parser docker
              Mem_Buf_Limit 10MB
              Skip_Long_Lines On
        EOT

        filters = <<-EOT
          [FILTER]
              Name kubernetes
              Match stockops.*
              Merge_Log On
              Keep_Log Off
              K8S-Logging.Parser On
              K8S-Logging.Exclude On
        EOT

        outputs = <<-EOT
          [OUTPUT]
              Name cloudwatch_logs
              Match stockops.api.*
              region ${var.region}
              log_group_name /aws/eks/${var.cluster_name}/stockops/api
              log_stream_prefix api-
              auto_create_group false

          [OUTPUT]
              Name cloudwatch_logs
              Match stockops.ai.*
              region ${var.region}
              log_group_name /aws/eks/${var.cluster_name}/stockops/ai
              log_stream_prefix ai-
              auto_create_group false
        EOT
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.cloudwatch,
    aws_cloudwatch_log_group.api,
    aws_cloudwatch_log_group.ai
  ]
}