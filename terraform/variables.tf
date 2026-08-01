variable "kubeconfig_path" {
  description = "Path to the kubeconfig used for bootstrap."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Kubeconfig context. Leave empty to use the current one."
  type        = string
  default     = ""
}

variable "gitops_repo_url" {
  description = "Repository Argo CD watches for desired state."
  type        = string
  default     = "https://github.com/shahriar-ahmed-seam/keel.git"
}

variable "gitops_revision" {
  description = "Branch or tag Argo CD tracks."
  type        = string
  default     = "main"
}

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version. Pinned deliberately."
  type        = string
  default     = "7.7.11"
}

variable "argocd_namespace" {
  type    = string
  default = "argocd"
}

variable "argocd_hostname" {
  description = "Hostname for the Argo CD ingress. Empty disables the ingress."
  type        = string
  default     = ""
}

variable "argocd_admin_password_bcrypt" {
  description = <<-EOT
    bcrypt hash of the Argo CD admin password. Generate with:
      htpasswd -nbBC 10 "" 'your-password' | tr -d ':\n' | sed 's/$2y/$2a/'
    Leave empty to keep the chart's generated initial secret.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "repo_credentials" {
  description = <<-EOT
    Deploy credentials for private repositories, keyed by repo URL. Only needed
    if any application repository is private; the public ones need nothing.
  EOT
  type = map(object({
    username = string
    password = string
  }))
  default   = {}
  sensitive = true
}

variable "manage_addons_with_terraform" {
  description = <<-EOT
    false (default) means Argo CD owns the cluster add-ons via
    gitops/applications/platform-addons.yaml — one system of record.
    Set true only for a throwaway local cluster where you want Terraform to
    install them directly and skip the GitOps round trip.
  EOT
  type    = bool
  default = false
}

variable "install_rollouts_dashboard" {
  type    = bool
  default = true
}

variable "labels" {
  description = "Applied to every namespace this module creates."
  type        = map(string)
  default = {
    "app.kubernetes.io/managed-by"      = "terraform"
    "keel.somokolonlabs.com/managed-by" = "keel"
  }
}
