locals {
  groups = {
    public = {
      settings   = var.public_node_group
      subnet_ids = var.public_subnet_ids
      labels     = { workload = "public" }
      taints     = []
    }
    application = {
      settings   = var.application_node_group
      subnet_ids = var.application_subnet_ids
      labels     = { workload = "application" }
      taints     = []
    }
    database = {
      settings   = var.database_node_group
      subnet_ids = var.database_subnet_ids
      labels     = { workload = "database" }
      taints = [{
        key    = "workload"
        value  = "database"
        effect = "NO_SCHEDULE"
      }]
    }
  }

  autoscaler_tags = merge(
    {
      for group_name, group in local.groups : "${group_name}-enabled" => {
        group_name = group_name
        key        = "k8s.io/cluster-autoscaler/enabled"
        value      = "true"
      }
    },
    {
      for group_name, group in local.groups : "${group_name}-cluster" => {
        group_name = group_name
        key        = "k8s.io/cluster-autoscaler/${var.cluster_name}"
        value      = "owned"
      }
    },
    {
      for group_name, group in local.groups : "${group_name}-label" => {
        group_name = group_name
        key        = "k8s.io/cluster-autoscaler/node-template/label/workload"
        value      = group_name
      }
    },
    {
      database-taint = {
        group_name = "database"
        key        = "k8s.io/cluster-autoscaler/node-template/taint/workload"
        value      = "database:NoSchedule"
      }
    }
  )
}

resource "aws_iam_role" "nodes" {
  for_each = local.groups

  name_prefix = "${var.project_name}-${each.key}-node-"
  description = "EC2 instance role for the ${each.key} EKS managed node group."
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = merge(var.tags, { Name = "${var.project_name}-${each.key}-node" })
}

resource "aws_iam_role_policy_attachment" "nodes" {
  for_each = {
    for pair in flatten([
      for group_name in keys(local.groups) : [
        for policy in [
          "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
          "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
          ] : {
          id         = "${group_name}-${basename(policy)}"
          group_name = group_name
          policy_arn = policy
        }
      ]
    ]) : pair.id => pair
  }

  role       = aws_iam_role.nodes[each.value.group_name].name
  policy_arn = each.value.policy_arn
}

resource "aws_launch_template" "nodes" {
  for_each = local.groups

  name_prefix            = "${var.project_name}-${each.key}-"
  update_default_version = true
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  network_interfaces {
    device_index                = 0
    associate_public_ip_address = each.key == "public"
    security_groups             = [var.node_security_group_ids[each.key]]
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.node_volume_size_gib
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.project_name}-${each.key}-node" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${var.project_name}-${each.key}-root" })
  }

  tags = merge(var.tags, { Name = "${var.project_name}-${each.key}-launch-template" })
}

resource "aws_eks_node_group" "workers" {
  for_each = local.groups

  cluster_name    = var.cluster_name
  node_group_name = "${var.project_name}-${each.key}"
  node_role_arn   = aws_iam_role.nodes[each.key].arn
  subnet_ids      = each.value.subnet_ids
  version         = var.cluster_version
  instance_types  = each.value.settings.instance_types
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = "ON_DEMAND"

  scaling_config {
    min_size     = each.value.settings.min_size
    desired_size = each.value.settings.desired_size
    max_size     = each.value.settings.max_size
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.nodes[each.key].id
    version = aws_launch_template.nodes[each.key].latest_version
  }

  labels = merge(each.value.labels, { "nodegroup" = each.key })

  dynamic "taint" {
    for_each = each.value.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  tags = merge(var.tags, {
    Name                                            = "${var.project_name}-${each.key}"
    "k8s.io/cluster-autoscaler/enabled"             = "true"
    "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
  })

  depends_on = [aws_iam_role_policy_attachment.nodes]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

resource "aws_autoscaling_group_tag" "autoscaler" {
  for_each = local.autoscaler_tags

  autoscaling_group_name = aws_eks_node_group.workers[each.value.group_name].resources[0].autoscaling_groups[0].name

  tag {
    key                 = each.value.key
    value               = each.value.value
    propagate_at_launch = false
  }
}
