# ─────────────────────────────────────────────
# 1. ADOT Collector IRSA Role (X-Ray 쓰기 권한)
# ─────────────────────────────────────────────
resource "aws_iam_role" "adot" {
  name = "seoul-adot-collector-role"

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
          "${var.eks_oidc_issuer}:sub" = "system:serviceaccount:opentelemetry:adot-collector"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "adot_xray" {
  role       = aws_iam_role.adot.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# ─────────────────────────────────────────────
# 2. opentelemetry 네임스페이스
# ─────────────────────────────────────────────
resource "kubernetes_namespace" "otel" {
  metadata {
    name = "opentelemetry"
  }
}

# ─────────────────────────────────────────────
# 3. ADOT Collector Helm 릴리스 (Deployment)
# ─────────────────────────────────────────────
resource "helm_release" "adot_collector" {
  name       = "adot-collector"
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  namespace  = kubernetes_namespace.otel.metadata[0].name
  version    = "0.97.1"
  timeout    = 600

  values = [
    yamlencode({
      mode = "deployment"
      image = {
        repository = "public.ecr.aws/aws-observability/aws-otel-collector"
        tag        = "v0.41.1"
      }
      command = {
        name = "/awscollector"
      }

      serviceAccount = {
        create = true
        name   = "adot-collector"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.adot.arn
        }
      }

      config = {
        receivers = {
          otlp = {
            protocols = {
              grpc = { endpoint = "0.0.0.0:4317" }
              http = { endpoint = "0.0.0.0:4318" }
            }
          }
        }
        processors = {
          batch = {}
        }
        exporters = {
          awsxray = {
            region = "ap-northeast-2"
          }
        }
        service = {
          pipelines = {
            traces = {
              receivers  = ["otlp"]
              processors = ["batch"]
              exporters  = ["awsxray"]
            }
          }
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace.otel]
}