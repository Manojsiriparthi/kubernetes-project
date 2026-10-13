module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.37.2"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version
  vpc_id          = var.vpc_id

  control_plane_subnet_ids              = var.control_plane_subnet_ids
  subnet_ids                            = var.control_plane_subnet_ids
  cluster_additional_security_group_ids = var.cluster_additional_security_group_ids

  cluster_endpoint_private_access          = true
  cluster_endpoint_public_access           = true
  cluster_endpoint_public_access_cidrs     = var.cluster_endpoint_public_access_cidrs
  cluster_enabled_log_types                = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  create_cloudwatch_log_group              = true
  cloudwatch_log_group_retention_in_days   = var.cluster_log_retention_days
  create_kms_key                           = true
  cluster_encryption_config                = { resources = ["secrets"] }
  enable_irsa                              = true
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
  }

  tags = var.tags
}
