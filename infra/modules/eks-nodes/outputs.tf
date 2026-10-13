output "node_group_names" {
  value = { for name, group in aws_eks_node_group.workers : name => group.node_group_name }
}

output "node_role_arns" {
  value = { for name, role in aws_iam_role.nodes : name => role.arn }
}
