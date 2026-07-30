# GKE ArgoCD GitOps — Production-Grade Dev/Test/Prod on One Cluster

A hands-on, advanced-level GitOps platform: **Argo CD** + **Argo Rollouts** managing **dev, test, and prod** on a single existing GKE cluster, using the **App of Apps** pattern, one environment-agnostic **Helm chart**, sync hooks, custom health checks, notifications, and layered RBAC.

This README is written so a complete beginner can clone this repo and run it end-to-end, **and** so you can use it to genuinely prepare for an advanced ArgoCD/GitOps interview — every concept below is backed by a real file in this repo, not a textbook example.

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [Architecture](#2-architecture)
3. [Repository Structure](#3-repository-structure)
4. [Prerequisites](#4-prerequisites)
5. [Core ArgoCD/GitOps Concepts](#5-core-argocdgitops-concepts)
6. [Setting Up CI/CD Secrets (WIF)](#6-setting-up-cicd-secrets-workload-identity-federation)
7. [Step-by-Step Setup](#7-step-by-step-setup)
8. [Promotion Flow — Dev to Prod](#8-promotion-flow--dev-to-prod)
9. [Verification Commands](#9-verification-commands)
10. [Troubleshooting](#10-troubleshooting)
11. [Interview Questions](#11-interview-questions)
12. [Future Improvements](#12-future-improvements)

---

## 1. Introduction

Most "ArgoCD tutorial" content stops at "install Argo CD, sync one Application." This repo goes further, into the territory an advanced interview actually probes:

- **Sync hooks & sync waves** (ordering, PreSync migration-style checks)
- **Drift handling** (`ignoreDifferences` for HPA/Rollout-managed fields)
- **Progressive delivery** (Argo Rollouts canary in prod, not a plain rolling Deployment)
- **Custom health checks** (teaching Argo CD to understand a CRD it's never seen)
- **Notifications** (Slack on sync failure / prod deploy)
- **Layered RBAC** (global `argocd-rbac-cm` + per-environment `AppProject` roles)
- **App of Apps vs ApplicationSet** (both patterns present, one active, one documented)

Only **one GCP account / one GKE cluster** is assumed — `dev`, `test`, and `prod` are three isolated namespaces on that same cluster, not three separate clusters.

---

## 2. Architecture

```
                        ┌───────────────────────────┐
                        │   Existing GKE Cluster      │
                        │  (built by gke-infra-       │
                        │   terraform, a separate repo)│
                        └─────────────┬─────────────┘
                                      │ bootstrap/ (Terraform) installs onto it
                                      ▼
        ┌──────────────────────────────────────────────────────┐
        │   argocd namespace         │   argo-rollouts namespace │
        │   Argo CD (server,          │   Argo Rollouts controller │
        │   repo-server, controller)  │   (canary engine for prod)  │
        └──────────────┬───────────────────────────────────────┘
                       │ watches this Git repo
                       ▼
        ┌──────────────────────────────────────────────────────┐
        │        argocd-apps/root-app.yaml (App of Apps)          │
        │   watches argocd-apps/environments/ → creates:           │
        │        demo-app-dev  demo-app-test  demo-app-prod         │
        └───────┬───────────────┬───────────────┬─────────────────┘
                ▼               ▼               ▼
        ┌──────────┐    ┌──────────┐    ┌────────────────────┐
        │  dev ns   │    │  test ns  │    │  prod ns             │
        │ Deployment │    │ Deployment │    │ Argo Rollouts canary │
        │ auto-sync  │    │ auto-sync  │    │ MANUAL sync only     │
        └──────────┘    └──────────┘    └────────────────────┘
```

CI (`.github/workflows/ci.yml`) never touches the cluster — it only builds the demo app's Docker image, scans it, pushes it, and commits a bumped image tag into `values-dev.yaml`. That Git commit is the entire "deploy" action; Argo CD does the rest.

---

## 3. Repository Structure

```
gke-argocd-gitops/
├── app-src/                          # Actual demo microservice (Flask) + Dockerfile
├── bootstrap/                        # Terraform: installs Argo CD + Argo Rollouts + namespaces
│   ├── providers.tf                  #   reads the EXISTING cluster via a data source
│   ├── argocd.tf                     #   helm_release "argocd" + helm_release "argo_rollouts"
│   ├── namespaces.tf                 #   dev/test/prod + ResourceQuota + NetworkPolicy
│   └── ...
├── argocd-config/                    # Cluster-wide Argo CD behavior (applied via kubectl)
│   ├── argocd-rbac-cm.yaml            #   global RBAC policy
│   ├── argocd-notifications-cm.yaml   #   Slack alerts
│   └── argocd-cm-health-check.yaml    #   custom Lua health check for Job
├── argocd-projects/                  # AppProject = RBAC + resource-kind boundary, per env
├── argocd-apps/
│   ├── root-app.yaml                  # THE App of Apps root — apply this once, by hand
│   ├── environments/
│   │   ├── dev-app.yaml               # auto-sync
│   │   ├── test-app.yaml              # auto-sync
│   │   └── prod-app.yaml              # MANUAL sync + ignoreDifferences + Slack subscriptions
│   └── applicationset-example.yaml    # alternate pattern, documented, NOT active by default
├── apps/demo-app/                    # ONE Helm chart, THREE values files
│   ├── values-dev.yaml / values-test.yaml / values-prod.yaml
│   └── templates/
│       ├── deployment.yaml            # used when rollout.enabled = false (dev/test)
│       ├── rollout.yaml               # used when rollout.enabled = true (prod) — canary
│       ├── presync-hook-job.yaml      # PreSync hook, sync-wave "-1"
│       ├── hpa.yaml                   # targets Deployment OR Rollout automatically
│       └── service.yaml / ingress.yaml / serviceaccount.yaml
└── .github/workflows/ci.yml          # build → Trivy scan → push → bump values-dev.yaml → commit
```

---

## 4. Prerequisites

- The GKE cluster from the separate `gke-infra-terraform` repo already exists and is reachable
- `kubectl`, `helm`, `terraform`, and the [Argo CD CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/) installed locally
- `GCP_WIF_PROVIDER` / `GCP_SERVICE_ACCOUNT` GitHub secrets configured **for THIS repo specifically** — do not reuse the infra repo's secrets, they won't work here. This repo has its own dedicated `bootstrap/wif.tf` (a separate Workload Identity Pool, trusting only this repository) — see [Section 6](#6-setting-up-cicd-secrets-workload-identity-federation) for the exact commands.

---

## 5. Core ArgoCD/GitOps Concepts

### `Application` vs `AppProject`

An **`Application`** is "deploy THIS Helm chart/path, from THIS repo/revision, to THIS namespace" — one per environment here (`demo-app-dev`, `demo-app-test`, `demo-app-prod`). An **`AppProject`** is the security boundary around a group of Applications: which repos they may pull from, which destination namespaces they may write to, which Kubernetes *kinds* they're allowed to create (`namespaceResourceWhitelist`), and which RBAC roles exist inside that boundary. Every Application in this repo belongs to exactly one AppProject.

### Automated vs Manual Sync

`syncPolicy.automated { prune: true, selfHeal: true }` (dev/test) means Argo CD applies Git changes the moment it sees them, and reverts any manual `kubectl edit` back to match Git within minutes. **Omitting `automated` entirely** (prod) means Argo CD only ever computes and shows a diff — a human must run `argocd app sync demo-app-prod` to actually apply it. Git is still the single source of truth either way; only the *timing* of application changes.

### Sync Waves vs Sync Hooks

These solve different problems and get confused constantly:
- **Sync waves** (`argocd.argoproj.io/sync-wave: "-1"`) control **order** among normal resources within the *same* sync operation — lower numbers apply first.
- **Sync hooks** (`argocd.argoproj.io/hook: PreSync`) mark a resource as running at a specific *phase* of the sync lifecycle (`PreSync`, `Sync`, `PostSync`, `SyncFail`) — outside the normal resource list entirely, and Argo CD waits for it to complete before continuing.

This repo's `presync-hook-job.yaml` uses **both**: it's a `PreSync` hook (runs before the main sync), and also carries `sync-wave: "-1"` (in case multiple PreSync hooks exist later and need their own order).

### `ignoreDifferences` — Drift That's Supposed to Happen

`prod-app.yaml` ignores `/spec/replicas` on the `Rollout` resource, because the HPA constantly changes that field outside of Git. Without `ignoreDifferences`, Argo CD would either show prod as permanently `OutOfSync`, or — worse, with `selfHeal` on — fight the HPA every reconciliation loop. `ignoreDifferences` tells Argo CD "this specific field is allowed to diverge from Git; don't treat it as drift."

### Health Checks — Built-in and Custom

Argo CD ships with built-in health logic for common kinds (a `Deployment` is "Healthy" once its replicas are all ready). It does **not** know how to judge health for arbitrary CRDs. `argocd-config/argocd-cm-health-check.yaml` teaches it, via a small Lua script, how to read a `Job`'s `.status.succeeded`/`.status.failed` fields and report `Healthy`/`Degraded`/`Progressing` accordingly — the exact mechanism you'd use for any custom CRD your org builds.

### Notifications

`argocd-notifications-cm.yaml` defines **triggers** (when to fire — e.g. `on-sync-failed`), **templates** (what message to send), and **subscriptions** (which Slack channel). Prod additionally gets its own dedicated channel via annotations directly on `prod-app.yaml`, so a failed prod deploy pages someone instead of getting lost in routine dev/test noise.

### RBAC — Two Layers, Not One

`argocd-projects/*.yaml`'s `roles` answer **"what can this identity do inside THIS project?"** `argocd-config/argocd-rbac-cm.yaml` answers **"what can this identity do across Argo CD as a whole?"** — e.g., only `platform-admins` get `role:admin` globally, while `developers` only ever get project-scoped `dev/*` permissions. Both layers apply together; the effective permission is the most restrictive one that matches.

### App of Apps vs ApplicationSet

**App of Apps** (`root-app.yaml`, the pattern actually active here): one explicit YAML file per environment, full control over every field (different `syncPolicy`, different `ignoreDifferences`, different notification channel — as seen comparing `prod-app.yaml` to `dev-app.yaml`). Best when environments are **few and genuinely different**.

**ApplicationSet** (`applicationset-example.yaml`, documented but not active): one generator template stamps out N nearly-identical Applications automatically. Best when you have **many** near-identical targets (dozens of microservices, or many customer clusters) where per-target YAML would be pure repetition. This repo demonstrates both so you can speak to the trade-off directly in an interview.

### Progressive Delivery — Argo Rollouts Canary

Prod uses a `Rollout` (Argo Rollouts CRD) instead of a plain `Deployment`. Its `strategy.canary.steps` shifts traffic gradually — 20% → pause 60s → 50% → pause 120s → 100% — so a bad release only ever reaches a fraction of prod traffic before someone (or an automated analysis run, in a fuller setup) can abort it. Dev/test stay on plain `Deployment` — canary analysis is overkill before code has even been reviewed.

---

## 6. Setting Up CI/CD Secrets (Workload Identity Federation)

This repo's own `bootstrap/wif.tf` creates a **dedicated, least-privilege** Workload Identity Pool + service account just for this repo's CI — completely separate from the `gke-infra-terraform` repo's own WIF setup (see the comment block at the top of that file for why they must be separate, not shared).

```bash
cd bootstrap
terraform apply   # also creates the WIF pool/provider/SA, alongside Argo CD

terraform output gitops_ci_wif_provider          # → copy into GitHub secret GCP_WIF_PROVIDER
terraform output gitops_ci_service_account_email # → copy into GitHub secret GCP_SERVICE_ACCOUNT
```

In your GitHub repo: **Settings → Secrets and variables → Actions → New repository secret**, add both. `.github/workflows/ci.yml` picks them up automatically on the next push — no other configuration needed. This CI identity can **only** push images to Artifact Registry (`roles/artifactregistry.writer`); it has no access to the cluster, Cloud SQL, or anything else — if it ever leaked, the blast radius is "can push a Docker image," nothing more.

## 7. Step-by-Step Setup

```bash
# 1. Install Argo CD + Argo Rollouts + create dev/test/prod namespaces
cd bootstrap
terraform init
terraform apply

# 2. Get the initial Argo CD admin password
terraform output get_admin_password_command   # run the printed command

# 3. Access the Argo CD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
# open https://localhost:8080 → log in as `admin`

# 4. Apply cluster-wide Argo CD config (RBAC, notifications, custom health check)
kubectl apply -f argocd-config/

# 5. (If using Slack notifications) create the token secret first
kubectl create secret generic argocd-notifications-secret -n argocd \
  --from-literal=slack-token=<xoxb-your-slack-bot-token>

# 6. Apply the AppProjects
kubectl apply -f argocd-projects/

# 7. Bootstrap the App of Apps — the ONLY Application you ever apply by hand
kubectl apply -f argocd-apps/root-app.yaml

# Argo CD now creates demo-app-dev, demo-app-test, and demo-app-prod on its
# own. dev/test start auto-syncing immediately; prod waits for a manual sync.
```

---

## 8. Promotion Flow — Dev to Prod

```
1. Push to `main` (app-src/** changed)
     → CI builds the image, Trivy-scans it, pushes it, bumps values-dev.yaml
     → Argo CD auto-syncs demo-app-dev (PreSync hook is disabled in dev, so it's instant)

2. Verify in dev → open PR: main → test branch
     → merge → Argo CD auto-syncs demo-app-test
     → the PreSync Job hook runs FIRST (sync-wave -1), THEN the Deployment updates

3. QA signs off in test → open PR: test → prod branch
     → bump values-prod.yaml to an explicit, immutable tag (e.g. v1.2.0 — never "latest")
     → merge → demo-app-prod shows OutOfSync, but does NOT auto-apply

4. A release manager reviews the diff:
     argocd app diff demo-app-prod
   then syncs deliberately:
     argocd app sync demo-app-prod

5. Argo Rollouts takes over from there — traffic shifts 20% → 50% → 100%,
   pausing at each step. Watch it live:
     kubectl argo rollouts get rollout demo-app-prod -n prod --watch

6. If step 5 looks wrong at any point:
     kubectl argo rollouts abort demo-app-prod -n prod
   rolls back immediately to the last known-good version — no new Git commit needed.
```

---

## 9. Verification Commands

```bash
# Argo CD's view of the world
kubectl get applications -n argocd
argocd app get demo-app-dev
argocd app get demo-app-prod

# AppProjects and RBAC
kubectl get appprojects -n argocd
kubectl get cm argocd-rbac-cm -n argocd -o yaml

# The actual workloads per namespace
kubectl get deployments,pods,hpa -n dev
kubectl get deployments,pods,hpa -n test
kubectl get rollout,pods,hpa -n prod

# Sync hooks
kubectl get jobs -n test    # the PreSync check Job
kubectl logs -n test job/demo-app-presync-check

# Argo Rollouts canary status
kubectl argo rollouts get rollout demo-app-prod -n prod

# Namespace isolation
kubectl get resourcequota -n dev
kubectl get networkpolicy -n dev

# Notifications
kubectl get cm argocd-notifications-cm -n argocd -o yaml
kubectl get secret argocd-notifications-secret -n argocd
```

---

## 10. Troubleshooting

| # | Issue | Cause | Fix |
|---|---|---|---|
| 1 | `root-app` syncs but `demo-app-dev`/`test`/`prod` never appear | Repo URL in `root-app.yaml` still has a placeholder, or the repo isn't registered/reachable | Confirm `repoURL` matches your real GitHub URL exactly, and that the repo is public or has credentials registered |
| 2 | `demo-app-prod` stuck `Progressing` forever | The PreSync hook Job failed, and Argo CD is waiting on it before touching the Rollout | `kubectl get jobs -n prod` then `kubectl logs job/<name> -n prod` to see why the hook failed |
| 3 | Argo CD shows prod permanently `OutOfSync` even right after a sync | `ignoreDifferences` missing/misconfigured for the HPA-managed `spec/replicas` field | Confirm `prod-app.yaml`'s `ignoreDifferences` block targets the exact `group`/`kind`/`jsonPointers` of the resource actually drifting |
| 4 | `kubectl apply -f argocd-projects/` fails with an RBAC/permission error from Argo CD itself, not Kubernetes | You're logged in as a user without `role:admin` in `argocd-rbac-cm` | Log in as `admin` (the bootstrap password) for initial setup; assign real users to `platform-admins` afterward |
| 5 | Slack notifications never fire | `argocd-notifications-secret` missing, or the trigger's `when` condition doesn't match your app's actual `operationState.phase` values | `kubectl get secret argocd-notifications-secret -n argocd`; check `kubectl describe application demo-app-prod -n argocd` for the real phase values first |
| 6 | Rollout resource rejected: `no matches for kind "Rollout"` | The Argo Rollouts CRDs/controller aren't installed yet | Confirm `bootstrap/argocd.tf`'s `helm_release.argo_rollouts` applied successfully: `kubectl get pods -n argo-rollouts` |
| 7 | HPA shows `<unknown>` targets in prod | HPA is targeting `Deployment` but prod actually runs a `Rollout` (or vice versa) | Confirm `hpa.yaml`'s conditional `scaleTargetRef` matches `values-prod.yaml`'s `rollout.enabled` setting |
| 8 | CI workflow fails at the Trivy scan step | A HIGH/CRITICAL vulnerability was found in the base image or a dependency | Update `app-src/requirements.txt`/base image version; this is an intentional gate, not a bug |
| 9 | `argocd app sync demo-app-prod` says "permission denied" | Your Argo CD user isn't in the `release-managers` group/role | Check `argocd-rbac-cm.yaml`'s `g, gke-argocd-gitops:release-managers, role:release-manager` mapping against your actual logged-in identity |
| 10 | ApplicationSet example accidentally creates duplicate Applications | Someone applied `applicationset-example.yaml` while `root-app.yaml`'s App-of-Apps is also active | Only ever run ONE pattern at a time — this repo defaults to App of Apps; delete/don't-apply the ApplicationSet file unless you've deliberately switched patterns |
| 11 | CI fails at the "Authenticate to GCP" step with a token/audience error | GitHub secrets `GCP_WIF_PROVIDER`/`GCP_SERVICE_ACCOUNT` are missing, wrong, or copied from the **infra repo's** WIF setup instead of this repo's own (`bootstrap/wif.tf`) | Re-run `terraform output gitops_ci_wif_provider` and `terraform output gitops_ci_service_account_email` from THIS repo's `bootstrap/`, and re-paste them as secrets in THIS GitHub repo |
| 12 | `terraform apply` fails: `The WorkloadIdentityPool's display name must be less than or equal to 32 characters` | GCP hard-limits `display_name` on this resource to 32 chars | Fixed in this repo's `wif.tf` — `display_name = "GitOps CI Pool"` (14 chars); the longer explanation moved into `description`, which has a much higher limit |
| 13 | `helm_release.argocd` fails: `context deadline exceeded` / "Helm release was created but has a failed status" | Argo CD installs ~7 components; on a small/shared node pool (this cluster also runs WordPress) pulling every image and reaching Ready can take longer than Helm's 300s default | Fixed by setting `timeout = 600` and dropping `repoServer.replicas` to 1 in `argocd.tf`. If it STILL times out, run `kubectl get pods -n argocd` and `kubectl describe pod <pending-pod> -n argocd` to see the real reason (often `Insufficient cpu`/`Insufficient memory` on the node pool) |
| 14 | Re-running `terraform apply` after a failed Argo CD install fails again immediately, or does nothing | Terraform's state still has `helm_release.argocd` recorded as failed/partially-created, so it won't cleanly retry | Clean up first: `helm uninstall argocd -n argocd` (safe — Argo CD's own CRDs have a `resource-policy: keep` annotation, so they survive), then `terraform apply` again for a fresh install |
| 15 | `Warning: Helm uninstall returned an information message... resources were kept due to the resource policy` for the `applications.argoproj.io`/`applicationsets.argoproj.io`/`appprojects.argoproj.io` CRDs | This is **expected, not an error** — the Argo CD chart deliberately annotates its own CRDs with `helm.sh/resource-policy: keep`, so an `uninstall` never deletes existing `Application`/`AppProject` objects along with the controller | Safe to ignore. If you genuinely want to remove the CRDs too (e.g. tearing down the whole demo permanently): `kubectl delete crd applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io` manually, afterward |
| 16 | Several Argo CD pods stuck `Init:0/1` for many minutes, `argocd-server` shows `CreateContainerError`, liveness/readiness probes fail with `connection refused` | **Node resource starvation**, not a config bug — `kubectl describe nodes \| grep -A5 "Allocated resources"` shows CPU/memory requests already at ~90%+ before Argo CD even schedules. On a small/shared node pool (this cluster also runs WordPress), the default Argo CD chart's resource requests for ~7 components simply don't fit | Fixed in `argocd.tf`: `dex.enabled = false` (SSO isn't wired up yet — no reason to run an idle component), plus explicit, conservative `resources.requests/limits` set on every remaining component (`server`, `controller`, `repoServer`, `redis`, `notifications`, `applicationSet`) and on `argo-rollouts`. If pods are still stuck after re-applying, the node pool itself needs more capacity — resize it in the `gke-infra-terraform` repo (bigger machine type or more nodes), this repo can't fix a genuinely undersized cluster from the outside |
| 17 | `demo-app-dev`/`test`/`prod` stuck `OutOfSync`/`Missing`, retrying automated sync repeatedly; `kubectl describe application` shows `resource :ServiceAccount is not permitted in project dev` (or similar for other kinds) | The corresponding `AppProject`'s `namespaceResourceWhitelist` doesn't list every Kubernetes kind the Helm chart actually creates — Argo CD silently blocks any kind not explicitly whitelisted, even if the chart is otherwise valid | Fixed — all three `argocd-projects/*.yaml` now whitelist `ServiceAccount` (created by `serviceaccount.yaml`) and `networking.gke.io/ManagedCertificate` (created by `ingress.yaml` when `ingress.enabled: true`), alongside the kinds already listed. General lesson: whenever a new template/resource kind is added to the Helm chart, the relevant AppProject's whitelist must be updated too, or Argo CD will block it with exactly this message |
| 18 | Pod stuck `ImagePullBackOff`, event shows `failed to fetch oauth token... 404 Not Found` when pulling `.../demo-app/demo-app:dev-latest` | The Artifact Registry **repository itself** (`demo-app`) never existed — the infra repo's `artifact-registry` module only created `backup-images` (for the WordPress backup job), nothing for this project's demo app | Fixed — `bootstrap/artifact-registry.tf` in this repo now creates its own dedicated `demo-app` Docker repository (with a cleanup policy keeping the last 10 versions). Run `terraform apply` in `bootstrap/`, THEN push to `app-src/**` to trigger CI and actually populate an image at that tag |

---

## 11. Interview Questions

**A. Fundamentals**

1. **What is GitOps, in one sentence, and how does this repo embody it?**
   GitOps means Git is the single source of truth for desired state, and a controller (Argo CD) continuously reconciles the live cluster to match it — nothing is ever `kubectl apply`'d by a human or a CI pipeline directly; CI only ever changes Git, Argo CD does the actual applying.

2. **What's the difference between `Application` and `AppProject`?**
   `Application` = *what* to deploy and *where*. `AppProject` = the security/RBAC boundary a group of Applications must stay inside (allowed repos, allowed destination namespaces, allowed resource kinds, project-scoped roles).

3. **Explain `syncPolicy.automated` vs leaving it out.**
   With it: Argo CD applies Git changes immediately and (with `selfHeal`) reverts manual cluster edits back to match Git. Without it: Argo CD only computes/shows a diff; a human must trigger `sync` explicitly — this repo's prod uses exactly this for a deliberate manual gate.

4. **What do `prune: true` and `selfHeal: true` each individually control?**
   `prune` removes resources from the cluster that were deleted from Git. `selfHeal` reverts resources that were changed directly in the cluster (e.g. via `kubectl edit`) back to match Git — they're independent switches, both usually enabled together for full automation.

**B. Sync Mechanics**

5. **Sync waves vs sync hooks — what's the actual difference?**
   Waves order resources *within* the same sync operation (lower number first). Hooks run at specific *lifecycle phases* (`PreSync`/`Sync`/`PostSync`/`SyncFail`) outside the normal resource list, and Argo CD blocks the rest of the sync until a blocking hook completes. This repo's PreSync Job uses both concepts together.

6. **What does `hook-delete-policy: BeforeHookCreation` do, and why does the PreSync Job need it?**
   It deletes the previous run of that hook resource before creating a new one on the next sync. Without it, re-syncing would try to create a `Job` with a name that already exists (Jobs are immutable once created) and fail.

7. **What is `ignoreDifferences` for, and what's the risk of overusing it?**
   It tells Argo CD to treat specific fields as expected drift (e.g. HPA-managed `replicas`) rather than `OutOfSync`. Overusing it can hide *real* drift you actually wanted to catch — it should be scoped as narrowly as possible (this repo targets one exact `jsonPointer`, not the whole resource).

8. **How would you make Argo CD understand the health of a CRD it doesn't recognize?**
   A custom health check — a small Lua script under `resource.customizations.health.<group>_<Kind>` in `argocd-cm`, returning a `Healthy`/`Degraded`/`Progressing` status based on that resource's own status fields (demonstrated here for `batch/Job`).

**C. Progressive Delivery**

9. **Why use Argo Rollouts instead of a plain Deployment for prod?**
   A plain `Deployment`'s rolling update replaces all pods based only on readiness probes — it has no concept of gradually shifting *traffic* or pausing for analysis. A `Rollout`'s canary strategy shifts a percentage of traffic at a time, with pauses, so a bad release is caught while only affecting a fraction of real users.

10. **What happens if a canary step looks wrong halfway through?**
    `kubectl argo rollouts abort <name>` immediately stops the rollout and routes all traffic back to the last stable version — without needing a new Git commit or Argo CD sync.

11. **Why does the HPA need a different `scaleTargetRef` for prod vs dev/test in this repo?**
    Dev/test scale a plain `Deployment`; prod scales a `Rollout` (a different `apiVersion`/`kind` entirely) — the HPA's `scaleTargetRef` has to point at whichever object type actually owns the pods in that environment.

**D. RBAC & Notifications**

12. **Why does this repo have RBAC in two different places (`argocd-rbac-cm` and each `AppProject`)?**
    They answer different questions: `argocd-rbac-cm` is global ("can this identity use Argo CD at all, and at what default level"), while each `AppProject`'s `roles` are scoped ("what can this identity do specifically inside this one project's Applications"). Real permission is the intersection/most-restrictive match of both.

13. **How do notification triggers, templates, and subscriptions relate to each other?**
    A trigger defines *when* to fire (a condition on `app.status`). A template defines *what* message to send. A subscription (via annotation on an Application, or the ConfigMap's global `subscriptions` block) defines *who* receives it and through *which* service (Slack, email, etc).

**E. Patterns & Architecture**

14. **App of Apps vs ApplicationSet — when would you choose each?**
    App of Apps: few, genuinely different environments/apps needing individual field-level control (different sync policy, different notifications per app — as prod vs dev differ here). ApplicationSet: many near-identical targets where a single generator avoids repetitive, near-duplicate YAML.

15. **Why does this repo's CI pipeline never run `kubectl apply` or `helm upgrade` directly?**
    Because that would break GitOps entirely — the cluster's state would depend on two divergent sources (CI's imperative commands AND Git), instead of Git being the one source of truth Argo CD reconciles against.

16. **How does a single GKE cluster safely host dev, test, and prod at once?**
    Namespace-level isolation: separate namespaces, a `ResourceQuota` per namespace (hard CPU/memory/pod ceilings so one environment can't starve another), and a default-deny `NetworkPolicy` per namespace (so, e.g., a compromised dev pod can't reach a prod service over the network).

17. **Why does this repo create its own Workload Identity Pool instead of reusing the infra repo's?**
    Two reasons: (1) the infra repo's WIF *provider* has an `attribute_condition` that only trusts tokens from that specific repository — a token from this repo would be rejected before any IAM policy is even evaluated, so reusing it isn't even possible without editing the other repo's Terraform. (2) Least privilege — this repo's CI only ever needs to push a Docker image, so its dedicated service account only holds `roles/artifactregistry.writer`, nothing close to the infra repo's CI identity's broader permissions.

---

## 12. Future Improvements

- [ ] Wire up SSO (Dex/OIDC via GitHub teams) so `argocd-rbac-cm`'s group mappings reflect real identities instead of a single shared `admin` login
- [ ] Add an `AnalysisTemplate` (Argo Rollouts) so canary promotion is gated on real metrics (error rate, latency) instead of a fixed timer
- [ ] Add Argo CD's own Ingress + ManagedCertificate instead of `kubectl port-forward`
- [ ] Add `argocd-image-updater` as an alternative to the CI-commits-a-tag-bump pattern currently used for dev
- [ ] Add branch protection rules on `test`/`prod` requiring PR review before merge
- [ ] Add a second GKE cluster and demonstrate ApplicationSet's cluster generator for genuine multi-cluster delivery
