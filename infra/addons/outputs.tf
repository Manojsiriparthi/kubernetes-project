output "grafana_admin_password" {
  value       = module.eks_addons.grafana_admin_password
  description = "Grafana admin password; store securely."
  sensitive   = true
}

output "alb_controller_role_arn" {
  value       = module.eks_addons.alb_controller_role_arn
  description = "IRSA role ARN used by the AWS Load Balancer Controller."
}

output "cluster_autoscaler_role_arn" {
  value       = module.eks_addons.cluster_autoscaler_role_arn
  description = "IRSA role ARN used by Cluster Autoscaler."
}
