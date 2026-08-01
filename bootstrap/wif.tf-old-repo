#############################################################
# Dedicated Workload Identity Federation for THIS repo's CI
#############################################################
# Why a SEPARATE pool from the gke-infra-terraform repo's own bootstrap,
# instead of reusing it? Two reasons:
#
# 1. That pool's provider has an `attribute_condition` that trusts ONLY the
#    infra repo (`assertion.repository == "<owner>/gke-infra-terraform"`).
#    That condition is enforced BEFORE any IAM policy is even checked — a
#    token from THIS repo would be rejected outright no matter what IAM
#    bindings we added here. Reusing it would mean going and editing that
#    OTHER repo's Terraform state just to support this one — exactly the
#    kind of cross-project coupling this whole multi-repo setup is trying
#    to avoid (same reasoning as gke-infra-terraform's own 4-project split).
#
# 2. Least privilege: this CI pipeline only ever needs to push a Docker
#    image to Artifact Registry. It has no business holding the same broad
#    permissions the infra repo's CI identity needs (creating GKE clusters,
#    Cloud SQL instances, IAM bindings, etc).

resource "google_iam_workload_identity_pool" "gitops_ci" {
  workload_identity_pool_id = "gitops-ci-pool"
  display_name              = "GitOps CI Pool" # must be <= 32 chars — GCP hard limit
  description                = "Trusts GitHub Actions OIDC tokens from ONLY the linuxshakil/gke-argocd-gitops repo"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.gitops_ci.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  # The critical safety line: reject any token whose `repository` claim
  # isn't EXACTLY this repo. Update this if you ever fork/rename the repo.
  attribute_condition = "assertion.repository == \"linuxshakil/gke-argocd-gitops\""
}

# A dedicated, minimal-privilege service account — NOT the infra repo's
# broad github-actions-sa.
resource "google_service_account" "gitops_ci" {
  account_id   = "gitops-ci-sa"
  display_name = "CI identity for gke-argocd-gitops (image build + push ONLY)"
}

resource "google_project_iam_member" "gitops_ci_artifact_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.gitops_ci.email}"
}

resource "google_service_account_iam_member" "gitops_ci_wif_binding" {
  service_account_id = google_service_account.gitops_ci.name
  role                = "roles/iam.workloadIdentityUser"
  member              = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.gitops_ci.name}/attribute.repository/linuxshakil/gke-argocd-gitops"
}

output "gitops_ci_service_account_email" {
  value       = google_service_account.gitops_ci.email
  description = "→ GitHub secret GCP_SERVICE_ACCOUNT"
}

output "gitops_ci_wif_provider" {
  value       = google_iam_workload_identity_pool_provider.github.name
  description = "→ GitHub secret GCP_WIF_PROVIDER"
}
