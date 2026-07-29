terraform {
  required_version = ">= 1.15.0"

  required_providers {
    google     = { source = "hashicorp/google", version = "~> 6.50" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.35" }
    helm       = { source = "hashicorp/helm", version = "~> 2.16" }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# This repo does NOT create the cluster — it already exists (built by the
# separate gke-infra-terraform repo). We only READ it here, the same
# "data source, not resource" pattern used by apps/wordpress in that repo.
data "google_client_config" "default" {}

data "google_container_cluster" "existing" {
  name     = var.cluster_name
  location = var.zone
  project  = var.project_id
}

provider "kubernetes" {
  host                   = "https://${data.google_container_cluster.existing.endpoint}"
  cluster_ca_certificate = base64decode(data.google_container_cluster.existing.master_auth[0].cluster_ca_certificate)
  token                  = data.google_client_config.default.access_token
}

provider "helm" {
  kubernetes {
    host                   = "https://${data.google_container_cluster.existing.endpoint}"
    cluster_ca_certificate = base64decode(data.google_container_cluster.existing.master_auth[0].cluster_ca_certificate)
    token                  = data.google_client_config.default.access_token
  }
}
