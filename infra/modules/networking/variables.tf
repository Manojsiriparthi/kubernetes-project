# Inputs for the networking module.

# Prefix for resource names.
variable "project_name" {
  type = string
}

# IPv4 range of the whole VPC; subnets are carved out of it.
variable "vpc_cidr" {
  type = string
}

# How many availability zones to use (one subnet per tier per zone).
variable "az_count" {
  type = number

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4 (subnet CIDR layout supports 4 per tier)."
  }
}

variable "tags" {
  type = map(string)
}
