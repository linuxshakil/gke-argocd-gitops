# GKE ArgoCD GitOps — Dev / Test / Prod on One Cluster

A production-grade GitOps setup: **Argo CD** managing **dev, test, and prod** environments on a **single existing GKE cluster** (the one built by the separate `gke-infra-terraform` repo), using the **App of Apps** pattern and a single, environment-agnostic **Helm chart**.

## Architecture

```
bootstrap/                         Terraform — installs Argo CD + creates dev/test/prod
                                    namespaces (with ResourceQuota + NetworkPolicy) on the
                                    EXISTING cluster. Run once.

argocd-projects/                   AppProject per environment — the RBAC/security boundary.
                                    dev = loose, test = mirrors prod, prod = strict + manual.

argocd-apps/
  root-app.yaml                    The ONE Application you ever apply by hand.
  environments/
    dev-app.yaml                   Auto-sync, tracks `main` branch directly.
    test-app.yaml                  Auto-sync, tracks a dedicated `test` branch.
    prod-app.yaml                  MANUAL sync only, tracks a dedicated `prod` branch.

apps/demo-app/                     ONE Helm chart, THREE values files (values-dev/test/prod.yaml).
                                    Same templates, different sizing/replicas/domains per env.

.github/workflows/ci.yml           Builds the image, pushes it, and bumps values-dev.yaml —
                                    that Git commit is the ONLY "deploy" action. No kubectl apply.
```

## Why This Shape (in simple English)

- **One cluster, three namespaces** — I don't have three GCP accounts, so `dev`, `test`, and `prod` are three namespaces on the same GKE cluster, each with its own `ResourceQuota` (a hard ceiling so dev can't starve prod of CPU/memory) and `NetworkPolicy` (dev pods physically cannot reach prod pods over the network).
- **App of Apps** — instead of manually running `kubectl apply` on three separate Application YAMLs, I apply exactly one (`root-app.yaml`). It watches the `argocd-apps/environments/` folder and creates/updates the other three automatically. Add a fourth environment later? Just add one more YAML file to that folder — nothing else changes.
- **One Helm chart, three values files** — `dev`, `test`, and `prod` are never different code, only different *inputs* (replica count, resource sizing, whether autoscaling/ingress is on, which image tag). This is exactly the same "same logic, different `.tfvars`" idea from the Terraform side of this project, just in Helm's world.
- **Different sync policy per environment, on purpose:**
  - `dev`/`test` → `syncPolicy.automated` (`prune + selfHeal`) — Argo CD applies changes the moment they land in Git, and reverts any manual `kubectl edit` back to match Git.
  - `prod` → **no automated block at all**. A release manager has to run `argocd app sync demo-app-prod` (or click Sync in the UI) after reviewing the diff. Git is still the single source of truth — only the *moment of applying it* requires a deliberate human action.
- **CI never touches the cluster** — the GitHub Actions workflow only builds an image and commits a bumped tag into `values-dev.yaml`. Argo CD is the only thing with cluster credentials that actually changes anything — this is the core idea of GitOps: **Git is the API**, not `kubectl`.

## Promotion Flow — How a Change Reaches Production

```
1. Push to `main` → CI builds the image, bumps values-dev.yaml → Argo CD auto-syncs `dev`
2. Test in dev → open a Pull Request: main → test branch
3. Merge that PR → Argo CD auto-syncs `test` (values-test.yaml, already pinned to a real version)
4. QA signs off in test → open a Pull Request: test → prod branch, bump values-prod.yaml
   to an explicit, immutable tag (e.g. v1.2.0 — NEVER "latest")
5. Merge that PR → demo-app-prod shows OutOfSync in the Argo CD UI, but does NOT auto-apply
6. A release manager reviews the diff and runs:
       argocd app sync demo-app-prod
   → only now does production actually change
```

Every single step is a Git action (a push or a merged PR) — there's a full audit trail of exactly who changed what, when, and why, without anyone ever running `kubectl apply -f` by hand.

## Step-by-Step Setup

```bash
# 1. Install Argo CD + create dev/test/prod namespaces on the existing GKE cluster
cd bootstrap
terraform init
terraform apply

# 2. Get the initial admin password
terraform output get_admin_password_command   # run the printed command

# 3. Port-forward to the Argo CD UI (until you wire up its own Ingress)
kubectl port-forward svc/argocd-server -n argocd 8080:443
# open https://localhost:8080, log in as `admin`

# 4. Apply the AppProjects (RBAC boundaries)
kubectl apply -f argocd-projects/

# 5. Bootstrap the App of Apps — this is the ONLY Application you ever apply by hand
kubectl apply -f argocd-apps/root-app.yaml

# From this point on, Argo CD creates demo-app-dev, demo-app-test, and
# demo-app-prod on its own, and dev/test start auto-syncing immediately.
```

## Verification

```bash
# Argo CD's view of the world
kubectl get applications -n argocd
argocd app get demo-app-dev
argocd app get demo-app-prod   # should show Synced/OutOfSync + Healthy/Degraded

# The actual workloads per namespace
kubectl get deployments,pods,hpa -n dev
kubectl get deployments,pods,hpa -n test
kubectl get deployments,pods,hpa -n prod

# Confirm namespace isolation
kubectl get resourcequota -n dev
kubectl get networkpolicy -n dev
```

## Manually Syncing Production

```bash
argocd app diff demo-app-prod     # review exactly what would change first
argocd app sync demo-app-prod     # only then apply it
```

## Future Improvements

- [ ] Add Argo CD's own Ingress + ManagedCertificate (same GCE pattern as `demo-app`'s) instead of `port-forward`
- [ ] Add Argo CD Notifications (Slack) on sync failures and prod sync completion
- [ ] Add Argo Rollouts for canary/blue-green deploys in prod instead of a plain rolling Deployment
- [ ] Move from a static Helm repo credential Secret to Workload Identity Federation for Argo CD's own repo access, once it supports the same GitHub OIDC flow used elsewhere in this project
- [ ] Add branch protection rules on `test`/`prod` requiring PR review before merge
