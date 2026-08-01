# Terraform-managed add-ons for throwaway clusters only.
#
# In a real environment Argo CD owns these (gitops/applications/platform-addons.yaml)
# so there is one system of record. This module exists for `kind` clusters where
# waiting for a GitOps round trip during a 5-minute e2e run is pointless.

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
  }
}

variable "namespaces" {
  type = map(string)
}

variable "install_rollouts_dashboard" {
  type    = bool
  default = true
}

locals {
  common = {
    timeout         = 600
    atomic          = true
    cleanup_on_fail = true
  }
}

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = "4.12.0"
  namespace  = var.namespaces["ingress-nginx"]

  timeout         = local.common.timeout
  atomic          = local.common.atomic
  cleanup_on_fail = local.common.cleanup_on_fail

  values = [yamlencode({
    controller = {
      replicaCount = 1
      service      = { type = "NodePort" }
      # kind exposes 80/443 on the control-plane node via extraPortMappings.
      hostPort = { enabled = true }
      config = {
        "proxy-buffering"       = "off"
        "proxy-read-timeout"    = "3600"
        "use-forwarded-headers" = "true"
      }
      admissionWebhooks = { enabled = false }
    }
  })]
}

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.16.2"
  namespace  = var.namespaces["cert-manager"]

  timeout         = local.common.timeout
  atomic          = local.common.atomic
  cleanup_on_fail = local.common.cleanup_on_fail

  values = [yamlencode({
    crds = { enabled = true }
  })]
}

resource "helm_release" "keda" {
  name       = "keda"
  repository = "https://kedacore.github.io/charts"
  chart      = "keda"
  version    = "2.16.1"
  namespace  = var.namespaces["keda"]

  timeout         = local.common.timeout
  atomic          = local.common.atomic
  cleanup_on_fail = local.common.cleanup_on_fail
}

resource "helm_release" "argo_rollouts" {
  name       = "argo-rollouts"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-rollouts"
  version    = "2.38.2"
  namespace  = var.namespaces["argo-rollouts"]

  timeout         = local.common.timeout
  atomic          = local.common.atomic
  cleanup_on_fail = local.common.cleanup_on_fail

  values = [yamlencode({
    installCRDs = true
    dashboard   = { enabled = var.install_rollouts_dashboard }
  })]
}

resource "helm_release" "prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "67.5.0"
  namespace  = var.namespaces["observability"]

  # The stack is large; give it room and do not roll back a partial install on a
  # slow local cluster.
  timeout         = 1200
  atomic          = false
  cleanup_on_fail = false

  values = [yamlencode({
    crds = { enabled = true }
    prometheus = {
      prometheusSpec = {
        retention                               = "6h"
        serviceMonitorSelectorNilUsesHelmValues = false
        ruleSelectorNilUsesHelmValues           = false
        resources                               = { requests = { cpu = "100m", memory = "512Mi" } }
      }
    }
    grafana      = { adminPassword = "prom-operator" }
    alertmanager = { enabled = false }
    # Node-level exporters are noise on a single-node kind cluster.
    nodeExporter       = { enabled = false }
    kubeStateMetrics   = { enabled = true }
    prometheusOperator = { admissionWebhooks = { enabled = false } }
  })]
}

output "namespaces" {
  value = var.namespaces
}
