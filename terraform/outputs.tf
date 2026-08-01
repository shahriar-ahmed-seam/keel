output "argocd_namespace" {
  description = "Namespace Argo CD was installed into."
  value       = helm_release.argocd.namespace
}

output "argocd_chart_version" {
  value = helm_release.argocd.version
}

output "argocd_url" {
  description = "Argo CD UI, if an ingress hostname was configured."
  value       = var.argocd_hostname == "" ? "not exposed — use: kubectl -n ${var.argocd_namespace} port-forward svc/argocd-server 8080:80" : "https://${var.argocd_hostname}"
}

output "initial_admin_password_command" {
  description = "How to read the generated admin password when none was supplied."
  value = var.argocd_admin_password_bcrypt == "" ? "kubectl -n ${var.argocd_namespace} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d" : "set explicitly via argocd_admin_password_bcrypt"
}

output "gitops_repo" {
  description = "Repository Argo CD reconciles from."
  value       = "${var.gitops_repo_url}@${var.gitops_revision}"
}

output "next_steps" {
  value = <<-EOT
    Argo CD is installed and the root Application is applied. From here on the
    cluster follows Git — `kubectl apply` should not appear in a deploy again.

      1. watch discovery:   kubectl -n ${var.argocd_namespace} get applications -w
      2. platform status:   python cli/keel.py status
      3. promote a build:   python cli/keel.py promote --app sentinel --env staging --tag sha-abc1234 --push
      4. read the numbers:  python cli/keel.py timings
  EOT
}
