data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  public_subnets = [
    for index in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, index)
  ]
  application_subnets = [
    for index in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, 4 + index)
  ]
  database_subnets = [
    for index in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, 8 + index)
  ]
}

resource "aws_security_group" "cluster" {
  name_prefix = "${var.project_name}-cluster-"
  description = "EKS control plane endpoint access from this cluster's worker groups."
  vpc_id      = module.vpc.vpc_id
  tags        = merge(var.tags, { Name = "${var.project_name}-cluster" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "nodes" {
  for_each = toset(["public", "application", "database"])

  name_prefix = "${var.project_name}-${each.key}-nodes-"
  description = "Dedicated ${each.key} EKS worker security group."
  vpc_id      = module.vpc.vpc_id
  tags        = merge(var.tags, { Name = "${var.project_name}-${each.key}-nodes" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "cluster_from_nodes" {
  for_each = aws_security_group.nodes

  security_group_id            = aws_security_group.cluster.id
  referenced_security_group_id = each.value.id
  description                  = "Worker group ${each.key} access to the Kubernetes API."
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_security_group_egress_rule" "cluster_egress" {
  security_group_id = aws_security_group.cluster.id
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Control-plane replies and managed control-plane traffic."
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "node_kubelet_from_cluster" {
  for_each = aws_security_group.nodes

  security_group_id            = each.value.id
  referenced_security_group_id = aws_security_group.cluster.id
  description                  = "Kubelet access from the EKS control plane."
  ip_protocol                  = "tcp"
  from_port                    = 10250
  to_port                      = 10250
}

resource "aws_vpc_security_group_ingress_rule" "node_self" {
  for_each = aws_security_group.nodes

  security_group_id            = each.value.id
  referenced_security_group_id = each.value.id
  description                  = "Node and pod networking within the dedicated worker group."
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "node_inter_group" {
  for_each = {
    for pair in flatten([
      for target_name, target_sg in aws_security_group.nodes : [
        for source_name, source_sg in aws_security_group.nodes : {
          key              = "${target_name}-${source_name}"
          target_group_id  = target_sg.id
          source_group_id  = source_sg.id
          source_group_key = source_name
        } if target_name != source_name
      ]
    ]) : pair.key => pair
  }

  security_group_id            = each.value.target_group_id
  referenced_security_group_id = each.value.source_group_id
  description                  = "Cross-node Kubernetes pod traffic from the ${each.value.source_group_key} node group."
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_egress_rule" "node_egress" {
  for_each = aws_security_group.nodes

  security_group_id = each.value.id
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Outbound cluster, AWS API and container registry traffic."
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "frontend_targets" {
  security_group_id = aws_security_group.nodes["application"].id
  cidr_ipv4         = var.vpc_cidr
  description       = "VPC-local load balancer target and health-check traffic to frontend pods."
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080
}

resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "${var.project_name}-vpce-"
  description = "HTTPS access to private AWS service endpoints from cluster subnets."
  vpc_id      = module.vpc.vpc_id
  tags        = merge(var.tags, { Name = "${var.project_name}-vpc-endpoints" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoint_https" {
  security_group_id = aws_security_group.vpc_endpoints.id
  cidr_ipv4         = var.vpc_cidr
  description       = "HTTPS from nodes in the VPC."
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "endpoint_egress" {
  security_group_id = aws_security_group.vpc_endpoints.id
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Endpoint response traffic."
  ip_protocol       = "-1"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.21.0"

  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  public_subnets  = local.public_subnets
  private_subnets = local.application_subnets
  intra_subnets   = local.database_subnets

  public_subnet_names  = [for az in local.azs : "${var.project_name}-public-${az}"]
  private_subnet_names = [for az in local.azs : "${var.project_name}-application-${az}"]
  intra_subnet_names   = [for az in local.azs : "${var.project_name}-database-${az}"]

  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true
  enable_dns_hostnames   = true
  enable_dns_support     = true
  enable_flow_log        = false

  public_subnet_tags = {
    "kubernetes.io/role/elb"                        = "1"
    "kubernetes.io/cluster/${var.project_name}-eks" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"               = "1"
    "kubernetes.io/cluster/${var.project_name}-eks" = "shared"
  }
  intra_subnet_tags = {
    "workload"                                      = "database"
    "kubernetes.io/cluster/${var.project_name}-eks" = "shared"
  }

  tags = var.tags
}

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "5.21.0"

  vpc_id = module.vpc.vpc_id

  create_security_group = false
  security_group_ids    = [aws_security_group.vpc_endpoints.id]

  endpoints = {
    ecr_api = {
      service             = "ecr.api"
      private_dns_enabled = true
      subnet_ids          = concat(module.vpc.private_subnets, module.vpc.intra_subnets)
    }
    ecr_dkr = {
      service             = "ecr.dkr"
      private_dns_enabled = true
      subnet_ids          = concat(module.vpc.private_subnets, module.vpc.intra_subnets)
    }
    sts = {
      service             = "sts"
      private_dns_enabled = true
      subnet_ids          = concat(module.vpc.private_subnets, module.vpc.intra_subnets)
    }
    ec2 = {
      service             = "ec2"
      private_dns_enabled = true
      subnet_ids          = concat(module.vpc.private_subnets, module.vpc.intra_subnets)
    }
    autoscaling = {
      service             = "autoscaling"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
    }
    logs = {
      service             = "logs"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
    }
    monitoring = {
      service             = "monitoring"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
    }
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = concat(module.vpc.private_route_table_ids, module.vpc.intra_route_table_ids)
    }
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "vpc_flow" {
  name              = "/aws/vpc/${var.project_name}/flow-logs"
  retention_in_days = 90
  tags              = var.tags
}

resource "aws_iam_role" "vpc_flow" {
  name_prefix = "${var.project_name}-vpc-flow-"
  description = "Allows VPC Flow Logs to publish to CloudWatch Logs."
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "vpc_flow" {
  name = "${var.project_name}-vpc-flow-logs"
  role = aws_iam_role.vpc_flow.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      Resource = [
        "${aws_cloudwatch_log_group.vpc_flow.arn}:*"
      ]
    }]
  })
}

resource "aws_flow_log" "vpc" {
  vpc_id                   = module.vpc.vpc_id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.vpc_flow.arn
  iam_role_arn             = aws_iam_role.vpc_flow.arn
  max_aggregation_interval = 60
  tags                     = var.tags
}
