output "argocd_namespace" {
  value = kubernetes_namespace.argocd.metadata[0].name
}

output "environment_namespaces" {
  value = [for ns in kubernetes_namespace.env : ns.metadata[0].name]
}

output "get_admin_password_command" {
  value = "kubectl -n ${kubernetes_namespace.argocd.metadata[0].name} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}
