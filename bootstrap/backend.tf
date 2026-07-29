terraform {
  backend "gcs" {
    bucket = "gke-prod-demo-001-tf-state" # same bucket the infra repo's bootstrap created
    prefix = "gitops/argocd"              # its OWN prefix — independent state, independent lock
  }
}
