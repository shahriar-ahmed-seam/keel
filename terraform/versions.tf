terraform {
  required_version = ">= 1.9.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state is not optional for anything shared. Configure it with
  # `terraform init -backend-config=backend.hcl` so the bucket and credentials
  # never land in version control.
  #
  # backend "s3" {
  #   bucket         = "somokolon-tfstate"
  #   key            = "keel/terraform.tfstate"
  #   region         = "eu-central-1"
  #   dynamodb_table = "somokolon-tflock"
  #   encrypt        = true
  # }
}

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}

provider "helm" {
  kubernetes {
    config_path    = var.kubeconfig_path
    config_context = var.kube_context
  }
}

provider "kubectl" {
  config_path      = var.kubeconfig_path
  config_context   = var.kube_context
  load_config_file = true
  apply_retry_count = 3
}
