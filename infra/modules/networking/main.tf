# Networking for EKS: VPC, public/private/database subnets, internet gateway, NAT gateway,
# route tables and a security group for the database tier.

# Availability zones in the current region; we use the first `az_count` of them.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Each /20 subnet is carved from the VPC CIDR: indexes 0-3 public, 4-7 private, 8-11 database (one per AZ).
  public_subnets = [
    for index in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, index)
  ]
  private_subnets = [
    for index in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, 4 + index)
  ]
  database_subnets = [
    for index in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, 8 + index)
  ]
}

# Community VPC module: creates the VPC, subnets, internet gateway, NAT gateway and route tables.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.21.0"

  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  public_subnets   = local.public_subnets
  private_subnets  = local.private_subnets
  database_subnets = local.database_subnets

  public_subnet_names   = [for az in local.azs : "${var.project_name}-public-${az}"]
  private_subnet_names  = [for az in local.azs : "${var.project_name}-private-${az}"]
  database_subnet_names = [for az in local.azs : "${var.project_name}-database-${az}"]

  # One shared NAT gateway gives private and database subnets outbound internet (cheaper, not AZ-resilient).
  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false
  enable_dns_hostnames   = true
  enable_dns_support     = true

  map_public_ip_on_launch = false

  # Default SG has no rules so nothing can use it by accident.
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []
  manage_default_route_table     = true

  # Database subnets get their own route table and subnet group; outbound only via NAT, never via the internet gateway.
  create_database_subnet_group           = true
  create_database_subnet_route_table     = true
  create_database_internet_gateway_route = false
  create_database_nat_gateway_route      = true

  # Subnet tags let the AWS Load Balancer Controller pick subnets: public = internet-facing, private = internal.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                        = "1"
    "kubernetes.io/cluster/${var.project_name}-eks" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"               = "1"
    "kubernetes.io/cluster/${var.project_name}-eks" = "shared"
  }

  tags = var.tags
}

# Security group for the database tier.
resource "aws_security_group" "database" {
  name_prefix = "${var.project_name}-database-"
  description = "PostgreSQL access from private application subnets only; no egress."
  vpc_id      = module.vpc.vpc_id
  tags        = merge(var.tags, { Name = "${var.project_name}-database" })

  lifecycle {
    create_before_destroy = true
  }
}

# One rule per private subnet: only application nodes may reach PostgreSQL on 5432.
resource "aws_vpc_security_group_ingress_rule" "database_postgres" {
  for_each = toset(local.private_subnets)

  security_group_id = aws_security_group.database.id
  cidr_ipv4         = each.value
  description       = "PostgreSQL from private application subnet ${each.value}."
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
}
