#############################################################
# Artifact Registry — demo-app images
#############################################################
# This repository never existed anywhere. The infra repo's own
# infra/modules/artifact-registry only created "backup-images" (for the
# WordPress backup CronJob) — this gitops repo's CI needs its OWN repository
# to push the demo-app's Docker images into, so it's created here,
# self-contained, same reasoning as this repo's dedicated wif.tf.

resource "google_artifact_registry_repository" "demo_app" {
  location      = var.region
  repository_id = "demo-app"
  format        = "DOCKER"
  description   = "Docker images for the gke-argocd-gitops demo-app"

  # Keep the last 10 images per environment tag prefix, clean up the rest —
  # otherwise every CI run leaves an image behind forever.
  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }
}

output "demo_app_artifact_registry" {
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.demo_app.repository_id}"
  description = "Full registry path — must match ci.yml's REPO/image path and values*.yaml's image.repository"
}
