# GKE + Argo CD GitOps Project — Complete Simple Guide

This README explains **everything** we built, in simple words. If you are new to Terraform, GitHub Actions, or Argo CD, you should be able to read this top to bottom and understand what is happening and why.

---

## Table of Contents

1. [What Is This Project?](#1-what-is-this-project)
2. [The Two Repositories](#2-the-two-repositories)
3. [Big Picture — How Everything Connects](#3-big-picture--how-everything-connects)
4. [Part A: Terraform — Building the Foundation](#4-part-a-terraform--building-the-foundation)
5. [Part B: GitHub Actions — The Automation](#5-part-b-github-actions--the-automation)
6. [Part C: Argo CD — How Deployment Actually Happens](#6-part-c-argo-cd--how-deployment-actually-happens)
7. [Branching Strategy](#7-branching-strategy)
8. [Complete Step-by-Step Setup (From Zero)](#8-complete-step-by-step-setup-from-zero--full-hands-on-guide)
9. [Bonus: What If We Had Separate GCP Accounts for Dev/Test/Prod?](#9-bonus-what-if-we-had-separate-gcp-accounts-for-devtestprod)
10. [Common Problems and Fixes](#10-common-problems-and-fixes)
11. [Interview Questions (Quick Reference)](#11-interview-questions-quick-reference)

---

## 1. What Is This Project?

We built a small web application (`demo-app`) and set up a **complete professional pipeline** to deploy it to a Kubernetes cluster on Google Cloud (GKE). The pipeline has three environments — **dev**, **test**, and **prod** — all running on the **same cluster**, safely separated.

The two big ideas used everywhere in this project are:

- **Infrastructure as Code** — nothing is created by clicking in the Google Cloud Console. Every resource (cluster access, service accounts, Argo CD installation) is written as Terraform code.
- **GitOps** — nothing is deployed by typing `kubectl apply` by hand. Every deployment happens because someone pushed code to Git, and a tool called **Argo CD** noticed the change and applied it automatically.

---

## 2. The Two Repositories

We started with everything in **one** repository, but real companies never do that. So we split it into two, each with a clear, single job.

### Repo 1: `demo-app` — "The Code Repo"

This is where the actual application lives.

```
demo-app/
├── app.py                          # the actual Python (Flask) application
├── requirements.txt                # Python dependencies
├── Dockerfile                      # how to package the app into a container image
└── .github/workflows/ci.yml        # builds, scans, and pushes the image
```

Only developers work here. They never need to touch Kubernetes, Argo CD, or Terraform.

### Repo 2: `gke-argocd-gitops` — "The Deployment Repo"

This is where we describe **how** and **where** the app should run.

```
gke-argocd-gitops/
├── bootstrap/            # Terraform — sets up Argo CD, namespaces, service accounts
├── apps/demo-app/        # a Helm chart — the actual Kubernetes YAML template for our app
├── argocd-apps/          # Argo CD "Application" objects — one per environment
├── argocd-projects/      # Argo CD "AppProject" objects — permission boundaries
├── argocd-config/        # Argo CD settings — RBAC, Slack alerts, custom health checks
└── .github/workflows/promote.yml   # moves a tested image from one environment to the next
```

Only the platform/DevOps side touches this repo. Argo CD only ever watches **this** repo — it has no idea `demo-app` even exists.

### Why split them at all?

Imagine a junior developer accidentally pushes bad code. If everything was in one repo, that same push could theoretically touch production deployment settings too. By splitting the repos, a code change can **only** affect the `demo-app` repo. It takes a **separate, deliberate action** (the `promote.yml` workflow) to actually move that code toward production.

---

## 3. Big Picture — How Everything Connects

```
 Developer writes code
        │
        ▼
 Pushes to demo-app repo (main branch)
        │
        ▼
 GitHub Actions in demo-app: builds Docker image, scans it for security bugs,
 pushes it to Google Artifact Registry, then quietly sends a message into the
 gke-argocd-gitops repo saying "here is the new image tag for dev"
        │
        ▼
 Argo CD (running inside our GKE cluster) sees that gke-argocd-gitops repo
 changed, and automatically updates the "dev" environment
        │
        ▼
 We test it in dev. If good, we run "promote.yml" (a manual button click)
 to move that SAME image (not rebuilt!) into test, then later into prod
        │
        ▼
 Prod requires one more manual click to confirm the sync — nothing goes to
 production without a human saying "yes, go"
```

---

## 4. Part A: Terraform — Building the Foundation

All the Terraform code lives inside the `bootstrap/` folder of `gke-argocd-gitops`. Think of Terraform as "instructions to Google Cloud" written in a file, instead of clicking buttons on a website.

We do **not** use Terraform to create the GKE cluster itself in this repo — that cluster already exists (built earlier, by a separate infra project). This `bootstrap/` folder only installs things **on top of** that existing cluster.

### What each file does (in simple words)

| File | What it creates | Why we need it |
|---|---|---|
| `providers.tf` | Tells Terraform: "here is the existing GKE cluster, connect to it" | Terraform needs to know WHERE to send its commands |
| `namespaces.tf` | Creates 3 folders inside the cluster — `dev`, `test`, `prod` (called "namespaces" in Kubernetes) | Keeps the 3 environments separate on the same cluster, like 3 separate rooms in one house |
| | Also sets a limit on how much CPU/memory each namespace can use ("ResourceQuota") | So `dev` experiments can never accidentally eat all the resources and break `prod` |
| | Also blocks network traffic between namespaces ("NetworkPolicy") | So a `dev` pod can never accidentally talk to a `prod` pod |
| `argocd.tf` | Installs Argo CD itself, and Argo Rollouts (for advanced deployments), using Helm | This is the actual "brain" that will watch our Git repo and deploy things |
| `wif.tf` | Sets up a secure, passwordless way for GitHub Actions to talk to Google Cloud | Explained fully in Part B below |
| `artifact-registry.tf` | Creates a storage space in Google Cloud for our Docker images | Every image we build needs somewhere to live |
| `backend.tf` | Tells Terraform WHERE to save its own memory file (called "state") | So Terraform remembers what it already created, and doesn't create things twice |

### Terraform commands you actually run

```bash
cd bootstrap
terraform init      # downloads the tools Terraform needs
terraform plan       # shows you WHAT WILL CHANGE (a dry run, nothing happens yet)
terraform apply      # actually creates everything
```

Always read the `plan` output carefully before typing `apply` — this is your only chance to catch a mistake before it becomes real.

---

## 5. Part B: GitHub Actions — The Automation

We use **two different GitHub Actions workflows**, one in each repo, each doing a very different job.

### Workflow 1: `demo-app/.github/workflows/ci.yml` ("Build")

This runs every time code is pushed to `demo-app`'s `main` branch. In simple steps:

1. **Log in to Google Cloud** — using something called **Workload Identity Federation (WIF)**. This is important: we never store a Google Cloud password or key file anywhere in GitHub. Instead, GitHub proves its own identity with a short-lived, auto-expiring token, and Google Cloud trusts it (only for this exact repository). This is much safer than a password that never expires.
2. **Build the Docker image** — packages our app into a container, tagged with the Git commit ID (e.g. `sha-a1b2c3d`). This tag never changes for this exact build — it is permanent.
3. **Scan the image with Trivy** — a security tool that checks for known vulnerabilities. If a serious, fixable problem is found, the whole pipeline **stops** — the bad image never gets pushed anywhere.
4. **Push the image** to Artifact Registry.
5. **Tell the gke-argocd-gitops repo** — this step checks out the *other* repo and edits one file (`values-dev.yaml`) to say "use this new image tag," then commits and pushes that change. This is the one tricky part: since this is a *different* repository, GitHub's normal built-in token doesn't have permission to write there. We solved this using a **GitHub App**, which generates a short-lived permission token fresh every single run — nothing to manually renew, ever.

### Workflow 2: `gke-argocd-gitops/.github/workflows/promote.yml` ("Promote")

This does **not** build anything. It only **moves** an already-built, already-tested image from one environment to the next. You run it manually, whenever you decide something is ready to promote.

You give it 2-3 inputs:
- `target_env` — `test` or `prod`
- `image_tag` — the exact tag you copy from the current environment's values file
- `release_version` — only for prod, a friendly name like `v1.2.0`

It then:
1. Checks that the image tag genuinely exists (so a typo fails immediately, loudly)
2. For prod, also creates a friendly alias tag pointing at the exact same image (never a new build)
3. Updates the target environment's values file with the new tag
4. Opens a **Pull Request** — it never pushes directly, because a human should always review a promotion to `test` or `prod` before it happens

### Why is the image never rebuilt during promotion?

This is called **"build once, promote everywhere."** If we rebuilt the app separately for test and separately for prod, we could no longer be 100% sure it's the exact same code that was tested. By only ever re-tagging (never rebuilding), the artifact that reaches production is guaranteed to be byte-for-byte identical to what passed testing.

---

## 6. Part C: Argo CD — How Deployment Actually Happens

### What is Argo CD, really?

Argo CD is a program running inside our cluster whose only job is: **look at a Git repo, and make the cluster match it.** You never manually deploy anything — you change a file in Git, and Argo CD notices and copies that change into the cluster.

### Argo CD's Components (the actual pods running inside it)

| Component | Simple explanation |
|---|---|
| **argocd-server** | The front door — the web UI and the API that the CLI/UI talk to |
| **argocd-repo-server** | Reads our Git repo and "renders" the Helm chart into real Kubernetes YAML |
| **argocd-application-controller** | The real brain — constantly compares "what Git says should exist" with "what actually exists," and fixes any difference |
| **argocd-redis** | A cache, so the above two don't repeat expensive work every time |
| **argocd-dex-server** | Handles login via GitHub/Google (SSO) — **turned off** in our setup right now, since we haven't configured SSO yet |
| **argocd-notifications-controller** | Sends Slack alerts when something succeeds or fails |
| **argocd-applicationset-controller** | Can auto-generate many "Application" objects from one template (we have an example of this but don't actually use it — see below) |

### `Application` and `AppProject` — the two key objects

An **Application** is one specific instruction: "deploy this Helm chart, from this Git branch, into this namespace." We have three: `demo-app-dev`, `demo-app-test`, `demo-app-prod`.

An **AppProject** is a permission boundary around one or more Applications — which Git repo they may use, which namespace they may write to, and which Kubernetes object types they're even allowed to create. We have three: `dev`, `test`, `prod`.

### "App of Apps" — how we manage 3 Applications easily

Instead of manually creating each of the 3 Applications by hand, we created **one Application called `root-app`** that watches a folder (`argocd-apps/environments/`). Whatever `Application` YAML files exist in that folder, Argo CD creates automatically. Want a 4th environment later? Just add one more file there.

### Sync Policy — the most important setting per environment

| Environment | Sync Policy | What it means |
|---|---|---|
| `dev` | Automatic (`prune: true`, `selfHeal: true`) | The moment Git changes, Argo CD applies it — no human needed |
| `test` | Automatic | Same as dev — fast feedback for QA |
| `prod` | **Manual** (no automated block at all) | Argo CD only shows "this is out of date" — a human must explicitly run `argocd app sync` |

### Sync Hooks and Sync Waves

Before deploying to `test` or `prod`, we run a small "check" Job first (imagine it as a placeholder for a real database migration script). This uses a feature called a **PreSync Hook** — Argo CD runs this Job *before* touching anything else, and waits for it to finish successfully.

### Argo Rollouts — Canary Deployment for Prod

In `dev` and `test`, when a new version is deployed, all old pods are replaced with new ones fairly quickly (a normal "rolling update"). In `prod`, we use something smarter: a **canary deployment**.

Instead of switching 100% of pods immediately, it goes in steps:

```
20% new version → WAIT 60 seconds → 50% new version → WAIT 120 seconds → 100% new version
```

During each "WAIT" step, both the old and new versions are running side-by-side. If something looks wrong, we can run one command to instantly cancel and go back to the old version:

```bash
kubectl argo rollouts abort demo-app-prod -n prod
```

**Honest note:** our current setup shifts traffic *approximately*, based on the ratio of old-pods to new-pods behind the same Service (this is called "replica-ratio canary"). For a precise, guaranteed traffic percentage, you would add a service mesh like Istio — that's listed as a future improvement.

---

## 7. Branching Strategy

We use **different branching styles in each repo**, on purpose, because each repo has a different job.

### `demo-app` repo — Trunk-Based (simple)

```
main   (the only long-lived branch)
  │
  ├── feature/xyz     (temporary — created, worked on, merged, then deleted)
  └── fix/abc          (temporary)
```

Developers create a short branch, make a Pull Request into `main`, get it reviewed, and merge. Every merge into `main` triggers the CI workflow. There is no `dev`/`test`/`prod` branch here — the app repo does not need to know or care about environments at all.

### `gke-argocd-gitops` repo — Environment Branches

```
develop  →  maps to  →  dev environment    (auto-sync)
test     →  maps to  →  test environment   (auto-sync)
main     →  maps to  →  prod environment   (MANUAL sync)
```

- `develop` — CI pushes here directly and automatically. No protection needed.
- `test` — only reachable through a reviewed Pull Request (usually via `promote.yml`).
- `main` — the most protected branch. Requires a Pull Request, at least one human reviewer, and (ideally) passing checks. This is production — treat it that way.

### Why this asymmetry is correct

The app repo answers the question "what is the current best code?" The deployment repo answers a completely different question: "what is running in each environment, right now?" Mixing these two questions into one branch model creates confusion. Keeping them separate keeps each repo's job simple and obvious.

---

## 8. Complete Step-by-Step Setup (From Zero) — Full Hands-On Guide

This section is written for someone doing this for the very first time. Every click, every command, in the exact order we actually did them. Nothing is skipped.

### Prerequisites Checklist

- [ ] A Google Cloud account with billing enabled, and a GKE cluster already running (built by a separate infra project)
- [ ] A GitHub account
- [ ] `gcloud`, `kubectl`, `terraform`, `helm` installed locally
- [ ] `gcloud auth login` and `gcloud auth application-default login` already run once

---

### STEP 1 — Create the two GitHub repositories

1. Go to `github.com/new`
2. Create repo **`gke-argocd-gitops`** (this holds Terraform + Argo CD + Helm chart)
3. Create a second repo **`demo-app`** (this holds only the application source code)
4. Clone both locally

```bash
git clone https://github.com/<you>/gke-argocd-gitops.git
git clone https://github.com/<you>/demo-app.git
```

Put this project's `gke-argocd-gitops/` files into the first clone, and `demo-app/` files into the second. Push both to their `main` branch.

Then, in `gke-argocd-gitops`, also create the two other long-lived branches:

```bash
cd gke-argocd-gitops
git checkout -b develop
git push -u origin develop
git checkout -b test
git push -u origin test
git checkout main
```

---

### STEP 2 — Run Terraform (`bootstrap/`)

```bash
cd gke-argocd-gitops/bootstrap
terraform init
terraform plan       # READ this output before continuing
terraform apply
```

Type `yes` when prompted. This single `apply` creates:
- Argo CD + Argo Rollouts (installed onto your existing GKE cluster)
- The `dev`, `test`, `prod` namespaces (with resource limits and network isolation)
- A Workload Identity Pool (a secure, passwordless bridge between GitHub and Google Cloud)
- Two separate, isolated service accounts — one for each GitHub repo's CI
- The `demo-app` Artifact Registry repository (where Docker images will be stored)

When it finishes, keep this terminal open — you'll copy values from it in the next steps.

---

### STEP 3 — Get the Terraform outputs you'll need

```bash
# For the gke-argocd-gitops repo's CI secrets:
terraform output -raw gitops_ci_wif_provider
terraform output -raw gitops_ci_service_account_email

# For the demo-app repo's CI secrets:
terraform output -raw demo_app_ci_wif_provider
terraform output -raw demo_app_ci_service_account_email

# For logging into the Argo CD UI later:
terraform output get_admin_password_command
```

> **Important:** always use `-raw`. Without it, Terraform wraps the value in quotes, and if you paste that (quotes included) into a GitHub secret, authentication will fail with a confusing "Invalid form of account ID" error.

Copy all four values above somewhere safe (a text editor) — you'll paste them in Step 4.

---

### STEP 4 — Add GitHub Secrets to BOTH repos

**In `gke-argocd-gitops` repo:**

1. Go to the repo on GitHub → **Settings** tab → left sidebar → **Secrets and variables** → **Actions**
2. Click **New repository secret**
3. Add secret named `GCP_WIF_PROVIDER` → paste the `gitops_ci_wif_provider` value
4. Click **New repository secret** again
5. Add secret named `GCP_SERVICE_ACCOUNT` → paste the `gitops_ci_service_account_email` value

**In `demo-app` repo — same steps, but different values:**

1. `demo-app` repo → **Settings → Secrets and variables → Actions**
2. Add `GCP_WIF_PROVIDER` → paste the `demo_app_ci_wif_provider` value
3. Add `GCP_SERVICE_ACCOUNT` → paste the `demo_app_ci_service_account_email` value

At this point, both repos can authenticate to Google Cloud. Next, we need `demo-app` to also be able to write into `gke-argocd-gitops` — that needs one more thing: a GitHub App.

---

### STEP 5 — Create a GitHub App (so `demo-app`'s CI can commit into `gke-argocd-gitops`)

This is the part that's easy to forget a sub-step of. Go slowly here.

1. Go to **`github.com/settings/apps`** (for a personal account) or your organization's equivalent
2. Click **New GitHub App**
3. Fill in:
   - **GitHub App name**: anything unique, e.g. `gitops-bridge-<yourname>`
   - **Homepage URL**: any valid URL, e.g. `https://github.com/<you>/gke-argocd-gitops` (it's not actually used for anything functional)
   - **Webhook**: **uncheck** "Active" — we don't need webhooks
4. Scroll to **Permissions → Repository permissions**:
   - Find **Contents** → set to **Read and write**
   - Leave everything else as "No access"
5. Scroll down, choose **"Only on this account"**
6. Click **Create GitHub App**

**Now generate its private key:**

7. On the App's settings page, scroll to **Private keys** → click **Generate a private key**
8. A `.pem` file downloads automatically — **save it**, you cannot download it again (only generate a new one)

**Now note the App ID:**

9. At the top of the same settings page, you'll see **App ID** — a number (e.g. `123456`). Copy it.

**Now install the App:**

10. Left sidebar of the App's settings page → click **Install App**
11. Choose your account/organization
12. Select **"Only select repositories"** → choose `gke-argocd-gitops` **only**
13. Click **Install**

**Verify it worked:**

14. Go to `github.com/settings/installations` — you should see your App listed, with `gke-argocd-gitops` under its repository access

---

### STEP 6 — Add the GitHub App secrets to `demo-app` repo

1. `demo-app` repo → **Settings → Secrets and variables → Actions**
2. Add secret `GITOPS_APP_ID` → paste the numeric App ID from Step 5.9
3. Add secret `GITOPS_APP_PRIVATE_KEY` → open the downloaded `.pem` file in a text editor, copy **the entire contents** (including the `-----BEGIN...` and `-----END...` lines), paste all of it as the secret value

At this point, `demo-app`'s CI can now securely write into `gke-argocd-gitops`, and the token it uses is generated fresh every single run — nothing here will ever expire on you.

---

### STEP 7 — (Recommended) Turn on branch protection

1. `gke-argocd-gitops` repo → **Settings → Branches → Add branch protection rule**
2. Branch name pattern: `main` → check **"Require a pull request before merging"**, and ideally **"Require approvals"** (at least 1)
3. Repeat for `test` (same settings, or slightly lighter)
4. Leave `develop` unprotected — CI needs to push there directly

Also, still in Settings → **Actions → General** → scroll to **Workflow permissions** → make sure:
- **"Read and write permissions"** is selected
- **"Allow GitHub Actions to create and approve pull requests"** is checked (needed for `promote.yml` to open PRs)

---

### STEP 8 — Apply Argo CD's own configuration

```bash
cd gke-argocd-gitops
kubectl apply -f argocd-config/
kubectl apply -f argocd-projects/
```

This sets up Argo CD's global RBAC, Slack notification rules, a custom health check, and the three `AppProject` permission boundaries (`dev`, `test`, `prod`).

---

### STEP 9 — Bootstrap the App of Apps (the one manual `kubectl apply` you'll ever run)

```bash
kubectl apply -f argocd-apps/root-app.yaml
```

Within a minute or two, check that Argo CD created the three child Applications automatically:

```bash
kubectl get applications -n argocd
# Expect to see: root-app, demo-app-dev, demo-app-test, demo-app-prod
```

---

### STEP 10 — Log into the Argo CD UI (optional, but useful to see visually)

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open your browser to `http://localhost:8080` (**http, not https** — we run Argo CD in insecure mode since TLS is meant to terminate at a GKE Ingress, not here).

- Username: `admin`
- Password: run the command from Step 3's `get_admin_password_command` output

---

### STEP 11 — Trigger your first real build

```bash
cd ../demo-app
git commit --allow-empty -m "trigger first build"
git push origin main
```

Go to `demo-app` repo → **Actions** tab → watch the `CI - Build, Scan & Notify GitOps Repo` run. It will:
1. Build the Docker image
2. Scan it with Trivy
3. Push it to Artifact Registry
4. Commit a new image tag into `gke-argocd-gitops`'s `develop` branch (using the GitHub App token from Step 5)

---

### STEP 12 — Watch it deploy to `dev` automatically

```bash
kubectl get application demo-app-dev -n argocd
kubectl get pods -n dev
```

Within a few minutes (Argo CD's default polling interval), you should see a pod running with your new image.

---

### STEP 13 — Promote to `test`

1. Copy the current tag: `cat gke-argocd-gitops/apps/demo-app/values-dev.yaml`
2. `gke-argocd-gitops` repo → **Actions** tab → **"Promote Image (Retag, Never Rebuild)"** → **Run workflow**
3. Fill in: `target_env: test`, `image_tag: <the tag you copied>`, leave `release_version` blank
4. Run it — it opens a Pull Request into the `test` branch
5. Review and **merge** that PR
6. Argo CD auto-syncs `test` within a few minutes

---

### STEP 14 — Promote to `prod`

1. Copy the current tag from `values-test.yaml` this time
2. Run "Promote Image" again: `target_env: prod`, `image_tag: <copied tag>`, `release_version: v1.0.0` (or your own version number)
3. Review and merge the PR into `main`
4. Prod does **not** auto-sync — trigger it deliberately:

```bash
argocd login localhost:8080 --username admin --password <your-password> --insecure
argocd app diff demo-app-prod     # review what will change first
argocd app sync demo-app-prod
```

5. Watch the canary rollout happen live:

```bash
kubectl argo rollouts get rollout demo-app-prod -n prod --watch
```

You now have a fully working, professional GitOps pipeline running end to end.

---

## 9. Bonus: What If We Had Separate GCP Accounts for Dev/Test/Prod?

Right now, `dev`, `test`, and `prod` all live in **one GCP project** (`gke-prod-demo-001`), separated only by Kubernetes namespaces. This is common for smaller teams or personal projects, but many larger companies use **three separate GCP projects** — sometimes even three separate billing accounts — one per environment. Here's what would actually change.

### What stays the SAME

- The GitOps idea (Git as source of truth, Argo CD applying changes) doesn't change at all
- The Helm chart (`apps/demo-app/`) doesn't change — same templates work anywhere
- The branching strategy doesn't change
- `promote.yml`'s idea (retag, never rebuild, open a PR) doesn't change

### What actually changes

| Thing | One-project setup (current) | Three-projects setup |
|---|---|---|
| **GKE clusters** | 1 cluster, 3 namespaces | Usually 3 separate clusters (or at least 3 separate node pools), one per project |
| **Namespace isolation (`NetworkPolicy`, `ResourceQuota`)** | Needed, and we built it | **Not needed anymore** — projects are already fully separate, a `dev` VM/pod cannot even see `prod`'s network by default |
| **Artifact Registry** | 1 registry, all environments pull from it | Usually 3 separate registries, OR 1 shared "build" project's registry with cross-project IAM read access granted to test/prod projects |
| **Workload Identity Federation** | 1 pool trusting 2 repos, per-repo service accounts | Still similar, but now each environment's *deploy* identity (not just CI) needs project-specific permissions — e.g., a "prod deployer" service account that ONLY exists in the prod project |
| **Argo CD** | 1 Argo CD installation, manages all 3 namespaces on 1 cluster | Argo CD is typically installed **once**, usually in a separate "platform" project/cluster, and connects OUTWARD to the 3 environment clusters using registered cluster credentials (`argocd cluster add`) |
| **`Application`'s `destination`** | `namespace: dev` / `test` / `prod`, same `server: https://kubernetes.default.svc` | Each `Application`'s `destination.server` would point to a **different cluster's API endpoint** — this is the main YAML change needed |
| **Terraform** | 1 `bootstrap/` project, 1 `terraform.tfvars` | Usually 3 sets of `.tfvars` (or 3 separate Terraform workspaces/state files) — one per project, since `project_id` itself differs per environment |
| **IAM blast radius if compromised** | Limited by namespace RBAC + Kubernetes NetworkPolicy | Limited by GCP's own project boundary — much stronger, since a compromised dev project literally cannot reach prod's resources at the cloud-account level |
| **Cost tracking** | All 3 environments' costs mixed in one GCP billing view | Each environment's cost is cleanly separated automatically — no tagging/labels needed to tell them apart |

### The one thing that would need real, new work

Argo CD's `Application.spec.destination.server` currently says `https://kubernetes.default.svc` (a special shortcut meaning "the same cluster Argo CD itself is running on"). With 3 separate clusters, we would first register each external cluster with Argo CD:

```bash
argocd cluster add <context-name-for-prod-cluster>
```

Then update each environment's `Application` YAML to point `destination.server` at that specific cluster's real API URL instead of the shortcut. Everything else — the Helm chart, the branching, `promote.yml`, the sync policies — stays exactly the same.

### In short

Multi-project setup is **more isolated and more secure by default**, at the cost of **more infrastructure to manage** (multiple clusters, multiple registries, more Terraform state). Our single-project + namespace-isolation approach is a completely reasonable choice for smaller teams, and everything we built here would still make sense as a foundation if we ever needed to grow into the multi-project model later.

---

## 10. Common Problems and Fixes

| Problem | Likely Cause | Fix |
|---|---|---|
| Argo CD pods stuck `Init:0/1`, `CreateContainerError` | Node pool doesn't have enough CPU/memory | Check `kubectl describe nodes \| grep -A5 "Allocated resources"`; either resize the node pool or reduce component resource requests (already tuned down in `argocd.tf`) |
| `Application` shows `resource X is not permitted in project` | The `AppProject`'s allowed-kinds list is missing that Kubernetes kind | Add it to the relevant `argocd-projects/*.yaml` file |
| Promotion workflow fails: tag not found | Typed the tag from memory instead of copying it | Always copy the exact tag from the current environment's `values-*.yaml` |
| `non-fast-forward` git push error in a workflow | Branch name collided with a leftover branch from a previous run | Fixed — `promote.yml` now uses a unique branch name per run (includes the run ID) |
| GitHub Actions can't create a PR ("not permitted") | Repository setting blocks Actions from creating PRs | Repo Settings → Actions → General → enable "Allow GitHub Actions to create and approve pull requests" |
| Cross-repo commit works today, breaks months later | A personal access token silently expired | We use a GitHub App instead — its tokens are generated fresh every run, nothing to expire on a schedule |
| Prod pod ImagePullBackOff | The promoted tag doesn't actually exist yet, or the Artifact Registry repo itself was never created | Confirm the tag exists with `gcloud artifacts docker images describe`; confirm `bootstrap/artifact-registry.tf` was applied |

---

## 11. Interview Questions (Quick Reference)

- What is GitOps, and how is it different from a normal CI/CD pipeline that runs `kubectl apply`?
- Why do we split application code and deployment config into two repositories?
- What is "build once, promote everywhere," and why does rebuilding per environment break that promise?
- What's the difference between a Kubernetes `Deployment`'s rolling update and Argo Rollouts' canary strategy?
- What is Workload Identity Federation, and why is it safer than a downloaded service account key?
- Why does prod use manual sync while dev/test use automatic sync?
- What is the difference between an Argo CD `Application` and an `AppProject`?
- What is "App of Apps," and when would you use `ApplicationSet` instead?
- Why use a GitHub App instead of a personal access token for cross-repo automation?
- If you moved from one shared GCP project to three separate ones, what would actually need to change in this setup?

*(Full detailed answers to these — and many more — were given earlier in this conversation.)*
