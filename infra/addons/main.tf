provider "aws" {
  region = var.region
}

data "aws_eks_cluster" "target" {
  name = var.cluster_name
}

data "aws_iam_openid_connect_provider" "cluster" {
  url = data.aws_eks_cluster.target.identity[0].oidc[0].issuer
}

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.target.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.target.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.target.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.target.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
    }
  }
}

module "eks_addons" {
  source = "../modules/eks-addons"

  project_name           = var.project_name
  cluster_name           = var.cluster_name
  cluster_oidc_issuer    = data.aws_eks_cluster.target.identity[0].oidc[0].issuer
  cluster_oidc_arn       = data.aws_iam_openid_connect_provider.cluster.arn
  region                 = var.region
  vpc_id                 = data.aws_eks_cluster.target.vpc_config[0].vpc_id
  grafana_admin_password = var.grafana_admin_password
  tags                   = local.common_tags
}
