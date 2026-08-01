# Terraform's job here is narrow and deliberate: install Argo CD and hand it the
# one Application that discovers everything else. Add-ons, workloads and their
# configuration live in Git and are reconciled by Argo, not by `terraform apply`.
#
# Two systems of record for the same resource is the failure mode this avoids.

locals {
  # Namespaces Terraform owns because they must exist before Argo can sync into
  # them. Everything else is created by Argo with CreateNamespace=true.
  bootstrap_namespaces = [var.argocd_namespace]

  addon_namespaces = var.manage_addons_with_terraform ? [
    "ingress-nginx",
    "cert-manager",
    "observability",
    "keda",
    "argo-rollouts",
    "sealed-secrets",
  ] : []
}

resource "kubernetes_namespace_v1" "bootstrap" {
  for_each = toset(concat(local.bootstrap_namespaces, local.addon_namespaces))

  metadata {
    name   = each.value
    labels = var.labels
  }

  lifecycle {
    # Deleting a namespace deletes everything in it. Never do that implicitly.
    prevent_destroy = true
  }
}

# --------------------------------------------------------------------------- #
# Argo CD
# --------------------------------------------------------------------------- #
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = kubernetes_namespace_v1.bootstrap[var.argocd_namespace].metadata[0].name

  # Bootstrap should either work or fail loudly, not hang forever.
  timeout          = 900
  atomic           = true
  cleanup_on_fail  = true
  wait             = true
  wait_for_jobs    = true

  values = [
    yamlencode({
      global = {
        logFormat = "json"
      }

      configs = {
        params = {
          # TLS is terminated at the ingress; running it twice breaks gRPC.
          "server.insecure" = true
          # ApplicationSets need the controller to watch this repo's files.
          "applicationsetcontroller.enable.progressive.syncs" = true
        }
        cm = {
          "timeout.reconciliation" = "120s"
          "application.resourceTrackingMethod" = "annotation"
          # Long-running jobs (training runs, load tests) must not be pruned
          # mid-flight by a reconcile.
          "resource.exclusions" = yamlencode([
            {
              apiGroups = ["batch"]
              kinds     = ["Job"]
              clusters  = ["*"]
            }
          ])
        }
        secret = var.argocd_admin_password_bcrypt == "" ? {} : {
          argocdServerAdminPassword      = var.argocd_admin_password_bcrypt
          argocdServerAdminPasswordMtime = timestamp()
        }
      }

      controller = {
        replicas = 1
        metrics = {
          enabled = true
          serviceMonitor = { enabled = true }
        }
        resources = {
          requests = { cpu = "250m", memory = "512Mi" }
        }
      }

      repoServer = {
        replicas = 2
        metrics = {
          enabled = true
          serviceMonitor = { enabled = true }
        }
      }

      applicationSet = {
        replicas = 1
        metrics = {
          enabled = true
          serviceMonitor = { enabled = true }
        }
      }

      notifications = {
        enabled = true
        metrics = {
          enabled = true
          serviceMonitor = { enabled = true }
        }
      }

      server = {
        replicas = 2
        metrics = {
          enabled = true
          serviceMonitor = { enabled = true }
        }
        ingress = var.argocd_hostname == "" ? { enabled = false } : {
          enabled          = true
          ingressClassName = "nginx"
          hostname         = var.argocd_hostname
          annotations = {
            "cert-manager.io/cluster-issuer"                 = "letsencrypt-prod"
            "nginx.ingress.kubernetes.io/backend-protocol"   = "HTTP"
            "nginx.ingress.kubernetes.io/force-ssl-redirect" = "true"
          }
          tls = true
        }
      }

      dex = {
        # No SSO configured yet; leaving dex running would be an idle attack
        # surface. Enable it when an IdP exists.
        enabled = false
      }
    })
  ]
}

# Private repository credentials, only if any were supplied.
resource "kubernetes_secret_v1" "repo_credentials" {
  for_each = var.repo_credentials

  metadata {
    name      = "repo-${md5(each.key)}"
    namespace = kubernetes_namespace_v1.bootstrap[var.argocd_namespace].metadata[0].name
    labels = merge(var.labels, {
      "argocd.argoproj.io/secret-type" = "repository"
    })
  }

  data = {
    type     = "git"
    url      = each.key
    username = each.value.username
    password = each.value.password
  }

  depends_on = [helm_release.argocd]
}

# --------------------------------------------------------------------------- #
# Hand over to Git
# --------------------------------------------------------------------------- #
# The project boundary and the root Application are applied from the files in
# this repository so there is exactly one definition of each.
resource "kubectl_manifest" "appproject" {
  yaml_body          = file("${path.module}/../gitops/bootstrap/appproject.yaml")
  server_side_apply  = true
  wait               = true

  depends_on = [helm_release.argocd]
}

resource "kubectl_manifest" "root_application" {
  yaml_body         = replace(
    file("${path.module}/../gitops/bootstrap/root.yaml"),
    "https://github.com/shahriar-ahmed-seam/keel.git",
    var.gitops_repo_url,
  )
  server_side_apply = true
  wait              = true

  depends_on = [kubectl_manifest.appproject]
}

# --------------------------------------------------------------------------- #
# Optional: Terraform-managed add-ons for throwaway clusters
# --------------------------------------------------------------------------- #
module "addons" {
  source = "./modules/addons"
  count  = var.manage_addons_with_terraform ? 1 : 0

  namespaces                 = { for name in local.addon_namespaces : name => kubernetes_namespace_v1.bootstrap[name].metadata[0].name }
  install_rollouts_dashboard = var.install_rollouts_dashboard

  depends_on = [kubernetes_namespace_v1.bootstrap]
}
