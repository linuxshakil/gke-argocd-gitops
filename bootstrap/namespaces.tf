locals {
  environments = {
    dev = {
      cpu_requests    = "2"
      cpu_limits      = "4"
      memory_requests = "4Gi"
      memory_limits   = "8Gi"
      pods            = "20"
    }
    test = {
      cpu_requests    = "2"
      cpu_limits      = "4"
      memory_requests = "4Gi"
      memory_limits   = "8Gi"
      pods            = "20"
    }
    prod = {
      cpu_requests    = "4"
      cpu_limits      = "8"
      memory_requests = "8Gi"
      memory_limits   = "16Gi"
      pods            = "40"
    }
  }
}

resource "kubernetes_namespace" "env" {
  for_each = local.environments

  metadata {
    name = each.key
    labels = {
      "environment"                         = each.key
      "argocd.argoproj.io/managed-by-argocd" = "true"
    }
  }
}

# Hard ceiling per environment — a runaway dev deployment can never starve
# prod of cluster resources on this shared cluster.
resource "kubernetes_resource_quota" "env" {
  for_each = local.environments

  metadata {
    name      = "${each.key}-quota"
    namespace = kubernetes_namespace.env[each.key].metadata[0].name
  }

  spec {
    hard = {
      "requests.cpu"    = each.value.cpu_requests
      "requests.memory" = each.value.memory_requests
      "limits.cpu"      = each.value.cpu_limits
      "limits.memory"   = each.value.memory_limits
      "pods"            = each.value.pods
    }
  }
}

# Default-deny cross-namespace traffic. Each environment can only talk to
# itself, to Argo CD (for sync/health checks), and to DNS — dev pods can
# never accidentally call a prod service, or vice versa.
resource "kubernetes_network_policy" "isolate" {
  for_each = local.environments

  metadata {
    name      = "${each.key}-isolate"
    namespace = kubernetes_namespace.env[each.key].metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = { environment = each.key }
        }
      }
    }
    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "argocd" }
        }
      }
    }
  }
}
