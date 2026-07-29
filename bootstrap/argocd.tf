resource "kubernetes_namespace" "argocd" {
  metadata {
    name = var.argocd_namespace
    labels = {
      "app.kubernetes.io/part-of" = "argocd"
    }
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = kubernetes_namespace.argocd.metadata[0].name
  create_namespace = false

  # Argo CD installs ~7 components (server, repo-server, application-
  # controller, redis, dex-server, notifications-controller, applicationset-
  # controller). On a small/shared node pool (this cluster also runs
  # WordPress), pulling every image and reaching Ready can take longer than
  # Helm's 300s default — bump it generously rather than fighting flaky
  # timeouts on every apply.
  timeout = 600

  # Production-grade settings — kept minimal and explicit rather than
  # accepting every chart default.
  values = [
    yamlencode({
      configs = {
        params = {
          "server.insecure" = true # TLS terminates at the GKE Ingress/BackendConfig, not at Argo CD's own pod
        }
      }
      server = {
        # Argo CD's own UI is exposed later via a normal Kubernetes Service +
        # Ingress, following the exact same BackendConfig/ManagedCertificate
        # pattern already used for WordPress in the infra repo.
        service = {
          type = "ClusterIP"
        }
      }
      controller = {
        replicas = 1
      }
      repoServer = {
        replicas = 1 # start at 1 on a small/shared cluster; bump to 2 for HA once you have node capacity to spare
      }
    })
  ]
}

# Register THIS gitops repo with Argo CD, so every Application below can
# reference it just by URL without repeating credentials everywhere.
resource "kubernetes_secret" "repo_credentials" {
  metadata {
    name      = "gke-argocd-gitops-repo"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type = "git"
    url  = var.gitops_repo_url
  }

  depends_on = [helm_release.argocd]
}

#############################################################
# Argo Rollouts — progressive delivery (canary) for prod
#############################################################
resource "kubernetes_namespace" "argo_rollouts" {
  metadata {
    name = "argo-rollouts"
  }
}

resource "helm_release" "argo_rollouts" {
  name             = "argo-rollouts"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-rollouts"
  version          = "2.37.7"
  namespace        = kubernetes_namespace.argo_rollouts.metadata[0].name
  create_namespace = false
}
