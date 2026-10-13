variable "project_name" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "az_count" {
  type = number
}

variable "tags" {
  type = map(string)
}
