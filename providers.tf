terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

# ── 오하이오(us-east-2) ──────────────────────────
provider "aws" {
  alias   = "ohio"
  region  = "us-east-2"
  profile = "siseon"
}

data "aws_eks_cluster" "ohio" {
  provider = aws.ohio
  name     = var.ohio_cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--profile", "siseon"]
  }
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--profile", "siseon"]
    }
  }
}

# ── 오하이오(us-east-2) k8s/helm ──────────────────
provider "kubernetes" {
  alias                  = "ohio"
  host                   = data.aws_eks_cluster.ohio.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.ohio.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.ohio_cluster_name, "--region", "us-east-2", "--profile", "siseon"]
  }
}

provider "helm" {
  alias = "ohio"
  kubernetes {
    host                   = data.aws_eks_cluster.ohio.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.ohio.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.ohio_cluster_name, "--region", "us-east-2", "--profile", "siseon"]
    }
  }
}