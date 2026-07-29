variable "project_id" {
  type        = string
  description = "GCP project ID where the existing GKE cluster lives"
}

variable "region" {
  type    = string
  default = "asia-south1"
}

variable "zone" {
  type    = string
  default = "asia-south1-a"
}

variable "cluster_name" {
  type        = string
  description = "Name of the EXISTING GKE cluster (created by the infra/ repo) that ArgoCD will be installed onto"
}

variable "argocd_namespace" {
  type    = string
  default = "argocd"
}

variable "argocd_chart_version" {
  type        = string
  default     = "7.7.11"
  description = "argo-cd Helm chart version — pinned deliberately, never left floating"
}

variable "gitops_repo_url" {
  type        = string
  description = "HTTPS URL of THIS gitops repo, e.g. https://github.com/linuxshakil/gke-argocd-gitops.git"
}
