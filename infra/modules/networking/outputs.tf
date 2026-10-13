output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnet_ids" {
  value = module.vpc.public_subnets
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "database_subnet_ids" {
  value = module.vpc.intra_subnets
}

output "cluster_security_group_id" {
  value = aws_security_group.cluster.id
}

output "node_security_group_ids" {
  value = { for name, group in aws_security_group.nodes : name => group.id }
}
