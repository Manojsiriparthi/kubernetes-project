# Inputs for the EKS node groups module.

# Prefix for node group, role and launch template names.
variable "project_name" {
  type = string
}

# Cluster the node groups join, and the Kubernetes version their AMIs match.
variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  type = string
}

# Subnets for each node group: public (edge), private (application) and database.
variable "public_subnet_ids" {
  type = list(string)
}

variable "application_subnet_ids" {
  type = list(string)
}

variable "database_subnet_ids" {
  type = list(string)
}

# Instance types and min/desired/max node counts for each group.
variable "public_node_group" {
  type = object({
    instance_types = list(string)
    min_size       = number
    desired_size   = number
    max_size       = number
  })
}

variable "application_node_group" {
  type = object({
    instance_types = list(string)
    min_size       = number
    desired_size   = number
    max_size       = number
  })
}

variable "database_node_group" {
  type = object({
    instance_types = list(string)
    min_size       = number
    desired_size   = number
    max_size       = number
  })
}

# Size in GiB of each node's encrypted root disk.
variable "node_volume_size_gib" {
  type = number
}

variable "tags" {
  type = map(string)
}

variable "network_addons_ready" {
  type        = list(string)
  default     = []
  description = "IDs of vpc-cni and kube-proxy add-ons; node groups are created only after they exist."
}
