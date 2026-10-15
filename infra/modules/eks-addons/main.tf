locals {
  oidc_issuer_host = replace(var.cluster_oidc_issuer, "https://", "")

  # Controllers run on the untainted public/edge node group.
  edge_node_selector = { workload = "public" }

  # Team tools (Argo CD, Prometheus, Grafana) share the application nodes with the app.
  team_node_selector = { workload = "application" }
  team_tolerations   = [{ key = "workload", operator = "Equal", value = "application", effect = "NoSchedule" }]

  # One shared internet-facing ALB for the team tools (Ingress group "team-tools"), one listener port per tool.
  # inbound-cidrs becomes the ALB security group: only team_access_cidrs can connect. Each tool also has its own login.
  # Without a certificate the ALB speaks plain HTTP, so set team_certificate_arn (needs a domain) before sending real passwords.
  team_tls = var.team_certificate_arn != null
  team_ingress_annotations = {
    for name, tool in {
      argocd     = { port = 8080, health = "/healthz" }
      grafana    = { port = 3000, health = "/api/health" }
      prometheus = { port = 9090, health = "/-/healthy" }
      alertmanager = { port = 9093, health = "/-/healthy" }
      } : name => merge(
      {
        "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
        "alb.ingress.kubernetes.io/target-type"      = "ip"
        "alb.ingress.kubernetes.io/group.name"       = "team-tools"
        "alb.ingress.kubernetes.io/inbound-cidrs"    = join(",", var.team_access_cidrs)
        "alb.ingress.kubernetes.io/healthcheck-path" = tool.health
        "alb.ingress.kubernetes.io/listen-ports"     = jsonencode([{ (local.team_tls ? "HTTPS" : "HTTP") = tool.port }])
      },
      local.team_tls ? { "alb.ingress.kubernetes.io/certificate-arn" = var.team_certificate_arn } : {}
    )
  }
}

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# IRSA roles
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "irsa_assume_role" {
  for_each = {
    vpc_cni = {
      test     = "StringEquals"
      subjects = ["system:serviceaccount:kube-system:aws-node"]
    }
    ebs_csi = {
      test     = "StringEquals"
      subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
    cloudwatch = {
      test = "StringLike"
      subjects = [
        "system:serviceaccount:amazon-cloudwatch:cloudwatch-agent",
        "system:serviceaccount:amazon-cloudwatch:fluent-bit",
      ]
    }
    alb_controller = {
      test     = "StringEquals"
      subjects = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
    cluster_autoscaler = {
      test     = "StringEquals"
      subjects = ["system:serviceaccount:kube-system:cluster-autoscaler"]
    }
  }

  statement {
    effect = "Allow"

    principals {
      type        = "Federated"
      identifiers = [var.cluster_oidc_arn]
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = each.value.test
      variable = "${local.oidc_issuer_host}:sub"
      values   = each.value.subjects
    }
  }
}

resource "aws_iam_role" "irsa" {
  for_each = data.aws_iam_policy_document.irsa_assume_role

  name_prefix        = "${var.cluster_name}-${replace(each.key, "_", "-")}-"
  assume_role_policy = each.value.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.irsa["vpc_cni"].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.irsa["ebs_csi"].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.irsa["cloudwatch"].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_policy" "alb_controller" {
  name_prefix = "${var.cluster_name}-alb-controller-"
  description = "AWS Load Balancer Controller permissions matching the pinned v2.13.3 release."
  policy      = file("${path.module}/aws-lbc-iam-policy.json")
  tags        = var.tags
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.irsa["alb_controller"].name
  policy_arn = aws_iam_policy.alb_controller.arn
}

data "aws_iam_policy_document" "cluster_autoscaler" {
  statement {
    sid    = "ReadClusterAndAutoScalingState"
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "eks:DescribeNodegroup",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ScaleOnlyTaggedClusterGroups"
    effect = "Allow"
    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:autoscaling:${var.region}:${data.aws_caller_identity.current.account_id}:autoScalingGroup:*:autoScalingGroupName/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/enabled"
      values   = ["true"]
    }

    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${var.cluster_name}"
      values   = ["owned"]
    }
  }
}

resource "aws_iam_policy" "cluster_autoscaler" {
  name_prefix = "${var.cluster_name}-cluster-autoscaler-"
  description = "Allows Cluster Autoscaler to inspect and scale only tagged EKS node groups."
  policy      = data.aws_iam_policy_document.cluster_autoscaler.json
  tags        = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  role       = aws_iam_role.irsa["cluster_autoscaler"].name
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
}

# ---------------------------------------------------------------------------
# EKS managed add-ons: vpc-cni, kube-proxy, coredns, ebs-csi, cloudwatch
# ---------------------------------------------------------------------------

data "aws_eks_addon_version" "this" {
  for_each = {
    vpc_cni    = "vpc-cni"
    kube_proxy = "kube-proxy"
    coredns    = "coredns"
    ebs_csi    = "aws-ebs-csi-driver"
    cloudwatch = "amazon-cloudwatch-observability"
  }

  addon_name         = each.value
  kubernetes_version = var.cluster_version
  most_recent        = true
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = var.cluster_name
  addon_name                  = "vpc-cni"
  addon_version               = data.aws_eks_addon_version.this["vpc_cni"].version
  service_account_role_arn    = aws_iam_role.irsa["vpc_cni"].arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [aws_iam_role_policy_attachment.vpc_cni]

  tags = var.tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = var.cluster_name
  addon_name                  = "kube-proxy"
  addon_version               = data.aws_eks_addon_version.this["kube_proxy"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = var.tags
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = var.cluster_name
  addon_name                  = "coredns"
  addon_version               = data.aws_eks_addon_version.this["coredns"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [aws_eks_addon.vpc_cni, aws_eks_addon.kube_proxy]

  tags = var.tags
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = var.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = data.aws_eks_addon_version.this["ebs_csi"].version
  service_account_role_arn    = aws_iam_role.irsa["ebs_csi"].arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [aws_iam_role_policy_attachment.ebs_csi, aws_eks_addon.coredns]

  tags = var.tags
}

resource "aws_eks_addon" "cloudwatch" {
  cluster_name                = var.cluster_name
  addon_name                  = "amazon-cloudwatch-observability"
  addon_version               = data.aws_eks_addon_version.this["cloudwatch"].version
  service_account_role_arn    = aws_iam_role.irsa["cloudwatch"].arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [aws_iam_role_policy_attachment.cloudwatch, aws_eks_addon.coredns]

  tags = var.tags
}

# Gate: Helm add-ons start only after every managed add-on is ACTIVE.
resource "terraform_data" "managed_addons_ready" {
  depends_on = [
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
    aws_eks_addon.coredns,
    aws_eks_addon.ebs_csi,
    aws_eks_addon.cloudwatch,
  ]
}

# ---------------------------------------------------------------------------
# Helm add-ons: load balancer controller, autoscaler, metrics-server (HPA), VPA, secrets CSI
# ---------------------------------------------------------------------------

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.13.3"

  values = [
    yamlencode({
      clusterName  = var.cluster_name
      region       = var.region
      vpcId        = var.vpc_id
      nodeSelector = local.edge_node_selector
      serviceAccount = {
        create      = true
        name        = "aws-load-balancer-controller"
        annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.irsa["alb_controller"].arn }
      }
    })
  ]

  depends_on = [terraform_data.managed_addons_ready, aws_iam_role_policy_attachment.alb_controller]
}

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  namespace  = "kube-system"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = "9.59.0"

  values = [
    yamlencode({
      autoDiscovery = { clusterName = var.cluster_name }
      awsRegion     = var.region
      nodeSelector  = local.edge_node_selector
      extraArgs     = { "balance-similar-node-groups" = "true" }
      rbac = {
        serviceAccount = {
          create      = true
          name        = "cluster-autoscaler"
          annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.irsa["cluster_autoscaler"].arn }
        }
      }
    })
  ]

  depends_on = [terraform_data.managed_addons_ready, aws_iam_role_policy_attachment.cluster_autoscaler]
}

# Provides the resource metrics API that HorizontalPodAutoscalers read.
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = "3.12.2"

  values = [
    yamlencode({
      nodeSelector = local.edge_node_selector
    })
  ]

  depends_on = [terraform_data.managed_addons_ready]
}

# Recommender only: gives right-sizing advice without evicting pods, so it can coexist with HPA.
resource "helm_release" "vpa" {
  name       = "vpa"
  namespace  = "kube-system"
  repository = "https://charts.fairwinds.com/stable"
  chart      = "vpa"
  version    = "4.7.2"

  values = [
    yamlencode({
      recommender              = { enabled = true, nodeSelector = local.edge_node_selector }
      updater                  = { enabled = false }
      admissionController      = { enabled = false }
    })
  ]

  depends_on = [helm_release.metrics_server]
}

# ---------------------------------------------------------------------------
# Team-only tools: Argo CD, Prometheus, Alertmanager and Grafana behind one shared ALB restricted to team_access_cidrs.
# They start after the load balancer controller and are removed before it, so the load balancers are cleaned up.
# ---------------------------------------------------------------------------

resource "random_password" "grafana_admin" {
  length  = 32
  special = false
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "8.3.0"
  timeout          = 600

  values = [
    yamlencode({
      global = {
        nodeSelector = local.team_node_selector
        tolerations  = local.team_tolerations
      }
      server = {
        service = { type = "ClusterIP" }
        ingress = {
          enabled          = true
          ingressClassName = "alb"
          annotations      = local.team_ingress_annotations.argocd
          path             = "/"
          pathType         = "Prefix"
        }
      }
      # The ALB talks plain HTTP to the pod, so Argo CD must not redirect to HTTPS itself.
      configs = { params = { "server.insecure" = true } }
    })
  ]

  depends_on = [helm_release.aws_load_balancer_controller]
}

# Prometheus + Alertmanager + Grafana. Data is not persisted: it is lost on pod restart.
resource "helm_release" "monitoring" {
  name             = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "75.15.0"
  timeout          = 900

  values = [
    yamlencode({
      # Alertmanager groups and routes alerts; with a Slack webhook they are sent to Slack, otherwise they only show in its UI.
      alertmanager = {
        service = { type = "ClusterIP" }
        ingress = {
          enabled          = true
          ingressClassName = "alb"
          annotations      = local.team_ingress_annotations.alertmanager
          paths            = ["/"]
          pathType         = "Prefix"
        }
        alertmanagerSpec = {
          nodeSelector = local.team_node_selector
          tolerations  = local.team_tolerations
        }
        config = {
          route = {
            receiver        = "default"
            group_by        = ["alertname", "namespace"]
            group_wait      = "30s"
            group_interval  = "5m"
            repeat_interval = "4h"
          }
          receivers = [merge(
            { name = "default" },
            var.alertmanager_slack_webhook_url == null ? {} : {
              slack_configs = [{ api_url = var.alertmanager_slack_webhook_url, send_resolved = true }]
            }
          )]
        }
      }
      # node-exporter runs on every node (all node groups) and exposes CPU, memory and disk metrics.
      nodeExporter = { enabled = true }
      # Alert rules (no templated text, so Helm does not try to expand it). Thresholds are deliberately low for learning.
      additionalPrometheusRulesMap = {
        school-demo-alerts = {
          groups = [{
            name = "school-demo.rules"
            rules = [
              {
                alert       = "NodeHighCPU"
                expr        = "100 - (avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100) > 30"
                for         = "5m"
                labels      = { severity = "warning" }
                annotations = { summary = "A node has used more than 30% CPU for 5 minutes." }
              },
              {
                alert       = "NodeHighMemory"
                expr        = "(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > 40"
                for         = "5m"
                labels      = { severity = "warning" }
                annotations = { summary = "A node has used more than 40% memory for 5 minutes." }
              },
              {
                alert       = "NodeHighDiskUsage"
                expr        = "(1 - node_filesystem_avail_bytes{mountpoint=\"/\",fstype!~\"tmpfs|overlay\"} / node_filesystem_size_bytes{mountpoint=\"/\",fstype!~\"tmpfs|overlay\"}) * 100 > 40"
                for         = "10m"
                labels      = { severity = "warning" }
                annotations = { summary = "A node root disk is more than 40% full." }
              },
              {
                alert       = "PersistentVolumeHighUsage"
                expr        = "kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes * 100 > 40"
                for         = "10m"
                labels      = { severity = "warning" }
                annotations = { summary = "A persistent volume (for example the database disk) is more than 40% full." }
              },
              {
                alert       = "PodCrashLooping"
                expr        = "increase(kube_pod_container_status_restarts_total{namespace=\"school-demo\"}[15m]) > 3"
                for         = "5m"
                labels      = { severity = "critical" }
                annotations = { summary = "A school-demo container restarted more than 3 times in 15 minutes." }
              },
            ]
          }]
        }
      }
      grafana = {
        adminPassword = random_password.grafana_admin.result
        nodeSelector  = local.team_node_selector
        tolerations   = local.team_tolerations
        service       = { type = "ClusterIP" }
        ingress = {
          enabled          = true
          ingressClassName = "alb"
          annotations      = local.team_ingress_annotations.grafana
          path             = "/"
          pathType         = "Prefix"
        }
      }
      prometheus = {
        service = { type = "ClusterIP" }
        ingress = {
          enabled          = true
          ingressClassName = "alb"
          annotations      = local.team_ingress_annotations.prometheus
          paths            = ["/"]
          pathType         = "Prefix"
        }
        prometheusSpec = {
          retention    = "7d"
          nodeSelector = local.team_node_selector
          tolerations  = local.team_tolerations
          # Pick up every ServiceMonitor/PodMonitor/rule in any namespace, not only ones labelled for this release.
          serviceMonitorSelectorNilUsesHelmValues = false
          podMonitorSelectorNilUsesHelmValues     = false
          ruleSelectorNilUsesHelmValues           = false
        }
      }
      prometheusOperator = {
        nodeSelector = local.team_node_selector
        tolerations  = local.team_tolerations
        admissionWebhooks = {
          patch = {
            nodeSelector = local.team_node_selector
            tolerations  = local.team_tolerations
          }
        }
      }
      "kube-state-metrics" = {
        nodeSelector = local.team_node_selector
        tolerations  = local.team_tolerations
      }
    })
  ]

  depends_on = [helm_release.aws_load_balancer_controller, helm_release.metrics_server]
}

# Node agents must also run on the tainted application and database nodes.
resource "helm_release" "secrets_store_csi_driver" {
  name       = "secrets-store-csi-driver"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
  chart      = "secrets-store-csi-driver"
  version    = "1.5.3"

  values = [
    yamlencode({
      syncSecret           = { enabled = true }
      enableSecretRotation = true
      linux                = { tolerations = [{ operator = "Exists" }] }
    })
  ]

  depends_on = [terraform_data.managed_addons_ready]
}

resource "helm_release" "secrets_store_csi_provider_aws" {
  name       = "secrets-store-csi-driver-provider-aws"
  namespace  = "kube-system"
  repository = "https://aws.github.io/secrets-store-csi-driver-provider-aws"
  chart      = "secrets-store-csi-driver-provider-aws"
  version    = "1.0.1"

  values = [
    yamlencode({
      tolerations = [{ operator = "Exists" }]
    })
  ]

  depends_on = [helm_release.secrets_store_csi_driver]
}

# On destroy, delete the app namespace first so the LB controller can remove the NLB/ALB
# and its ENIs/security groups before the VPC is torn down. Needs aws CLI and kubectl.
resource "terraform_data" "app_cleanup" {
  input = {
    cluster_name = var.cluster_name
    region       = var.region
  }

  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      export KUBECONFIG="$(mktemp)"
      aws eks update-kubeconfig --name "${self.input.cluster_name}" --region "${self.input.region}" >/dev/null
      # Argo CD would recreate the namespaces, so remove its Applications first, then every school-demo* namespace.
      kubectl delete applications.argoproj.io --all -n argocd --ignore-not-found --wait=false || true
      for ns in $(kubectl get namespaces -o name | grep 'school-demo' || true); do
        kubectl delete "$ns" --ignore-not-found --wait=true --timeout=15m
      done
      rm -f "$KUBECONFIG"
    EOT
  }

  depends_on = [
    helm_release.aws_load_balancer_controller,
    helm_release.secrets_store_csi_provider_aws,
  ]
}

output "grafana_admin_password" {
  value     = random_password.grafana_admin.result
  sensitive = true
}

output "role_arns" {
  value = { for name, role in aws_iam_role.irsa : name => role.arn }
}

output "addon_names" {
  value = [for addon in [
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
    aws_eks_addon.coredns,
    aws_eks_addon.ebs_csi,
    aws_eks_addon.cloudwatch,
  ] : addon.addon_name]
}
