# GKE + Argo CD GitOps Project — Complete Simple Guide

This README explains **everything** in this project, in simple words. If you are new to Terraform, GitHub Actions, or Argo CD, you should be able to read this top to bottom and understand what is happening and why.

---

## Table of Contents

1. [What Is This Project?](#1-what-is-this-project)
2. [The Two Repositories](#2-the-two-repositories)
3. [Big Picture — How Everything Connects](#3-big-picture--how-everything-connects)
4. [Part A: Terraform — Building the Foundation](#4-part-a-terraform--building-the-foundation)
5. [Part B: Helm — Packaging the App for Kubernetes](#5-part-b-helm--packaging-the-app-for-kubernetes)
6. [Part C: GitHub Actions — The Automation](#6-part-c-github-actions--the-automation)
7. [Part D: Argo CD — How Deployment Actually Happens](#7-part-d-argo-cd--how-deployment-actually-happens)
8. [Branching Strategy](#8-branching-strategy)
9. [Complete Step-by-Step Setup (From Zero)](#9-complete-step-by-step-setup-from-zero--full-hands-on-guide)
10. [Bonus: What If This Project Used Separate GCP Accounts for Dev/Test/Prod?](#10-bonus-what-if-this-project-used-separate-gcp-accounts-for-devtestprod)
11. [Common Problems and Fixes](#11-common-problems-and-fixes)
12. [Interview Questions](#12-interview-questions-with-answers)

---

## 1. What Is This Project?

This project is a small web application (`demo-app`) with a **complete professional pipeline** set up to deploy it to a Kubernetes cluster on Google Cloud (GKE). The pipeline has three environments — **dev**, **test**, and **prod** — all running on the **same cluster**, safely separated.

The two big ideas used everywhere in this project are:

- **Infrastructure as Code** — nothing is created by clicking in the Google Cloud Console. Every resource (cluster access, service accounts, Argo CD installation) is written as Terraform code.
- **GitOps** — nothing is deployed by typing `kubectl apply` by hand. Every deployment happens because someone pushed code to Git, and a tool called **Argo CD** noticed the change and applied it automatically.

---

## 2. The Two Repositories

Everything started out in **one** repository, but real companies never do that. So it is split into two repositories, each with a clear, single job.

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

This is where **how** and **where** the app should run gets described.

```
gke-argocd-gitops/
├── bootstrap/            # Terraform — sets up Argo CD, namespaces, service accounts
├── apps/demo-app/        # a Helm chart — the actual Kubernetes YAML template for the app
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
 Argo CD (running inside the GKE cluster) sees that the gke-argocd-gitops repo
 changed, and automatically updates the "dev" environment
        │
        ▼
 After testing in dev, running "promote.yml" (a manual button click)
 to move that SAME image (not rebuilt!) into test, then later into prod
        │
        ▼
 Prod requires one more manual click to confirm the sync — nothing goes to
 production without a human saying "yes, go"
```

---

## 4. Part A: Terraform — Building the Foundation

All the Terraform code lives inside the `bootstrap/` folder of `gke-argocd-gitops`. Think of Terraform as "instructions to Google Cloud" written in a file, instead of clicking buttons on a website.

Terraform is **not** used here to create the GKE cluster itself — that cluster already exists (built earlier, by a separate infra project). This `bootstrap/` folder only installs things **on top of** that existing cluster.

### What each file does (in simple words)

| File | What it creates | Why it's needed |
|---|---|---|
| `providers.tf` | Tells Terraform: "here is the existing GKE cluster, connect to it" | Terraform needs to know WHERE to send its commands |
| `namespaces.tf` | Creates 3 folders inside the cluster — `dev`, `test`, `prod` (called "namespaces" in Kubernetes) | Keeps the 3 environments separate on the same cluster, like 3 separate rooms in one house |
| | Also sets a limit on how much CPU/memory each namespace can use ("ResourceQuota") | So `dev` experiments can never accidentally eat all the resources and break `prod` |
| | Also blocks network traffic between namespaces ("NetworkPolicy") | So a `dev` pod can never accidentally talk to a `prod` pod |
| `argocd.tf` | Installs Argo CD itself, and Argo Rollouts (for advanced deployments), using Helm | This is the actual "brain" that watches the Git repo and deploys things |
| `wif.tf` | Sets up a secure, passwordless way for GitHub Actions to talk to Google Cloud | Explained fully in Part C below |
| `artifact-registry.tf` | Creates a storage space in Google Cloud for the Docker images | Every image that gets built needs somewhere to live |
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

## 5. Part B: Helm — Packaging the App for Kubernetes

Before getting to GitHub Actions and Argo CD, it helps to understand **Helm**, because both of those depend on it. This section assumes zero prior Helm knowledge.

### What problem does Helm solve?

Kubernetes needs YAML files to know what to run — a `Deployment` YAML, a `Service` YAML, and so on. Writing these by hand for three environments (dev, test, prod) means either maintaining three almost-identical copies of every file, or copy-pasting and editing by hand every time something changes. Both are error-prone.

**Helm solves this with templates and values.** Instead of three finished YAML files, there is **one template** with blanks in it, and **three small files that fill in those blanks differently** — one set of values for dev, one for test, one for prod.

### The Parts of a Helm Chart

A "chart" is just a folder with a specific structure. This project's chart lives at `apps/demo-app/`:

```
apps/demo-app/
├── Chart.yaml              # basic info: chart name, version
├── values.yaml              # DEFAULT values — used unless overridden
├── values-dev.yaml           # overrides specific to dev
├── values-test.yaml          # overrides specific to test
├── values-prod.yaml          # overrides specific to prod
└── templates/                # the actual Kubernetes YAML, with blanks
    ├── deployment.yaml
    ├── service.yaml
    ├── hpa.yaml
    ├── ingress.yaml
    ├── serviceaccount.yaml
    ├── rollout.yaml
    ├── presync-hook-job.yaml
    └── _helpers.tpl
```

**`Chart.yaml`** — just metadata, nothing to configure here:

```yaml
apiVersion: v2
name: demo-app
version: 0.1.0
appVersion: "1.0.0"
```

**`values.yaml`** — the base/default settings. A small piece of this project's actual file:

```yaml
replicaCount: 1

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 250m
    memory: 256Mi

image:
  repository: asia-south1-docker.pkg.dev/gke-prod-demo-001/demo-app/demo-app
  tag: "latest"
```

**`values-dev.yaml`** — only the settings that need to be *different* for dev. Anything not listed here just falls back to `values.yaml`'s default:

```yaml
image:
  tag: "sha-049a901"    # overrides the default "latest"

resources:
  requests:
    cpu: 50m              # smaller than the default 100m — dev doesn't need much
    memory: 64Mi
```

### How a Template Actually Works

Inside `templates/deployment.yaml`, instead of a fixed number of replicas, there's a placeholder:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "demo-app.fullname" . }}
spec:
  replicas: {{ .Values.replicaCount }}
  template:
    spec:
      containers:
        - name: demo-app
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
```

Anything inside `{{ }}` is Helm's templating language. `.Values.replicaCount` means "go look up `replicaCount` in the values files, and put that value right here." When Helm combines this template with `values.yaml` + `values-dev.yaml`, the final, real YAML it produces looks like this:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app-dev
spec:
  replicas: 1
  template:
    spec:
      containers:
        - name: demo-app
          image: "asia-south1-docker.pkg.dev/gke-prod-demo-001/demo-app/demo-app:sha-049a901"
```

Notice the image tag came from `values-dev.yaml` (`sha-049a901`), while `replicaCount` came from the base `values.yaml` (`1`), since `values-dev.yaml` didn't override it. **Whatever a specific values file sets, wins. Whatever it doesn't mention, falls back to the default.** This is the entire mechanism that lets one chart serve three different environments.

### A Couple of Small Building Blocks Worth Knowing

**`{{- if ... }}` — conditional blocks.** Some resources should only exist in some environments. `templates/rollout.yaml` only gets created when `rollout.enabled` is `true` (which is only the case in prod):

```yaml
{{- if .Values.rollout.enabled }}
apiVersion: argoproj.io/v1alpha1
kind: Rollout
...
{{- end }}
```

For dev and test (where `rollout.enabled` is `false`), Helm skips this block entirely — a plain `Deployment` gets used instead (from `templates/deployment.yaml`, which has the opposite condition, `{{- if not .Values.rollout.enabled }}`).

**`_helpers.tpl` — small reusable snippets.** Instead of typing the app's full name in every single template file, it's defined once:

```yaml
{{- define "demo-app.fullname" -}}
{{- printf "%s-%s" .Chart.Name .Values.environment }}
{{- end }}
```

Any template can now use `{{ include "demo-app.fullname" . }}` and get back `demo-app-dev`, `demo-app-test`, or `demo-app-prod` — automatically correct for whichever environment it's rendered for.

### Trying It Out Locally (No Cluster Needed)

Helm can render a chart to plain YAML without touching any cluster at all — useful for checking what a values file will actually produce before committing it:

```bash
cd apps/demo-app
helm template . -f values-dev.yaml
```

This prints the exact YAML that would be applied — a good way to catch a typo in a values file before it ever reaches Argo CD.

### Where Helm Fits Into This Project's Bigger Picture

Two different things in this project both use Helm, in two different ways:

1. **`bootstrap/argocd.tf`** uses Terraform's `helm_release` resource to install *other people's* charts (Argo CD's own chart, Argo Rollouts' chart) — nothing custom here, just installing existing software.
2. **`apps/demo-app/`** is a chart written specifically for this project's own application. Argo CD's `argocd-repo-server` component (see Part D below) is the one that actually runs `helm template` on this chart, using whichever `values-<env>.yaml` file that environment's `Application` object points at.

---

## 6. Part C: GitHub Actions — The Automation

This project uses **two different GitHub Actions workflows**, one in each repo, each doing a very different job.

### Workflow 1: `demo-app/.github/workflows/ci.yml` ("Build")

This runs every time code is pushed to `demo-app`'s `main` branch. In simple steps:

1. **Log in to Google Cloud** — using something called **Workload Identity Federation (WIF)**. This is important: no Google Cloud password or key file is ever stored anywhere in GitHub. Instead, GitHub proves its own identity with a short-lived, auto-expiring token, and Google Cloud trusts it (only for this exact repository). This is much safer than a password that never expires.
2. **Build the Docker image** — packages the app into a container, tagged with the Git commit ID (e.g. `sha-a1b2c3d`). This tag never changes for this exact build — it is permanent.
3. **Scan the image with Trivy** — a security tool that checks for known vulnerabilities. If a serious, fixable problem is found, the whole pipeline **stops** — the bad image never gets pushed anywhere.
4. **Push the image** to Artifact Registry.
5. **Tell the gke-argocd-gitops repo** — this step checks out the *other* repo and edits one file (`values-dev.yaml`) to say "use this new image tag," then commits and pushes that change. This is the one tricky part: since this is a *different* repository, GitHub's normal built-in token doesn't have permission to write there. This is solved using a **GitHub App**, which generates a short-lived permission token fresh every single run — nothing to manually renew, ever.

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

This is called **"build once, promote everywhere."** If the app were rebuilt separately for test and separately for prod, there could no longer be 100% certainty it's the exact same code that was tested. By only ever re-tagging (never rebuilding), the artifact that reaches production is guaranteed to be byte-for-byte identical to what passed testing.

---

## 7. Part D: Argo CD — How Deployment Actually Happens

### What is Argo CD, really?

Argo CD is a program running inside the cluster whose only job is: **look at a Git repo, and make the cluster match it.** You never manually deploy anything — you change a file in Git, and Argo CD notices and copies that change into the cluster.

### Argo CD's Components (the actual pods running inside it)

| Component | Simple explanation |
|---|---|
| **argocd-server** | The front door — the web UI and the API that the CLI/UI talk to |
| **argocd-repo-server** | Reads the Git repo and "renders" the Helm chart into real Kubernetes YAML |
| **argocd-application-controller** | The real brain — constantly compares "what Git says should exist" with "what actually exists," and fixes any difference |
| **argocd-redis** | A cache, so the above two don't repeat expensive work every time |
| **argocd-dex-server** | Handles login via GitHub/Google (SSO) — **turned off** in this setup right now, since SSO isn't configured yet |
| **argocd-notifications-controller** | Sends Slack alerts when something succeeds or fails |
| **argocd-applicationset-controller** | Can auto-generate many "Application" objects from one template (an example of this exists in the repo but isn't actually used — see below) |

### `Application` and `AppProject` — the two key objects

An **Application** is one specific instruction: "deploy this Helm chart, from this Git branch, into this namespace." There are three: `demo-app-dev`, `demo-app-test`, `demo-app-prod`.

An **AppProject** is a permission boundary around one or more Applications — which Git repo they may use, which namespace they may write to, and which Kubernetes object types they're even allowed to create. There are three: `dev`, `test`, `prod`.

### "App of Apps" — Managing 3 Applications Easily

Instead of manually creating each of the 3 Applications by hand, **one Application called `root-app`** was created that watches a folder (`argocd-apps/environments/`). Whatever `Application` YAML files exist in that folder, Argo CD creates automatically. Want a 4th environment later? Just add one more file there.

### Sync Policy — the most important setting per environment

| Environment | Sync Policy | What it means |
|---|---|---|
| `dev` | Automatic (`prune: true`, `selfHeal: true`) | The moment Git changes, Argo CD applies it — no human needed |
| `test` | Automatic | Same as dev — fast feedback for QA |
| `prod` | **Manual** (no automated block at all) | Argo CD only shows "this is out of date" — a human must explicitly run `argocd app sync` |

### Sync Hooks and Sync Waves

Before deploying to `test` or `prod`, a small "check" Job runs first (imagine it as a placeholder for a real database migration script). This uses a feature called a **PreSync Hook** — Argo CD runs this Job *before* touching anything else, and waits for it to finish successfully.

### Argo Rollouts — Canary Deployment for Prod

In `dev` and `test`, when a new version is deployed, all old pods are replaced with new ones fairly quickly (a normal "rolling update"). In `prod`, something smarter is used: a **canary deployment**.

Instead of switching 100% of pods immediately, it goes in steps:

```
20% new version → WAIT 60 seconds → 50% new version → WAIT 120 seconds → 100% new version
```

During each "WAIT" step, both the old and new versions are running side-by-side. If something looks wrong, one command instantly cancels and goes back to the old version:

```bash
kubectl argo rollouts abort demo-app-prod -n prod
```

**Honest note:** this current setup shifts traffic *approximately*, based on the ratio of old-pods to new-pods behind the same Service (this is called "replica-ratio canary"). For a precise, guaranteed traffic percentage, you would add a service mesh like Istio — that's listed as a future improvement.

---

## 8. Branching Strategy

This project uses **different branching styles in each repo**, on purpose, because each repo has a different job.

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

## 9. Complete Step-by-Step Setup (From Zero) — Full Hands-On Guide

This section is written for someone doing this for the very first time. Every click, every command, in the exact order they need to happen. Nothing is skipped.

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

At this point, both repos can authenticate to Google Cloud. Next, `demo-app` also needs to be able to write into `gke-argocd-gitops` — that needs one more thing: a GitHub App.

---

### STEP 5 — Create a GitHub App (so `demo-app`'s CI can commit into `gke-argocd-gitops`)

This is the part that's easy to forget a sub-step of. Go slowly here.

1. Go to **`github.com/settings/apps`** (for a personal account) or your organization's equivalent
2. Click **New GitHub App**
3. Fill in:
   - **GitHub App name**: anything unique, e.g. `gitops-bridge-<yourname>`
   - **Homepage URL**: any valid URL, e.g. `https://github.com/<you>/gke-argocd-gitops` (it's not actually used for anything functional)
   - **Webhook**: **uncheck** "Active" — webhooks aren't needed here
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

Open a browser to `http://localhost:8080` (**http, not https** — Argo CD runs in insecure mode here since TLS is meant to terminate at a GKE Ingress, not at Argo CD itself).

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

## 10. Bonus: What If This Project Used Separate GCP Accounts for Dev/Test/Prod?

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
| **Namespace isolation (`NetworkPolicy`, `ResourceQuota`)** | Needed, and already built | **Not needed anymore** — projects are already fully separate, a `dev` VM/pod cannot even see `prod`'s network by default |
| **Artifact Registry** | 1 registry, all environments pull from it | Usually 3 separate registries, OR 1 shared "build" project's registry with cross-project IAM read access granted to test/prod projects |
| **Workload Identity Federation** | 1 pool trusting 2 repos, per-repo service accounts | Still similar, but now each environment's *deploy* identity (not just CI) needs project-specific permissions — e.g., a "prod deployer" service account that ONLY exists in the prod project |
| **Argo CD** | 1 Argo CD installation, manages all 3 namespaces on 1 cluster | Argo CD is typically installed **once**, usually in a separate "platform" project/cluster, and connects OUTWARD to the 3 environment clusters using registered cluster credentials (`argocd cluster add`) |
| **`Application`'s `destination`** | `namespace: dev` / `test` / `prod`, same `server: https://kubernetes.default.svc` | Each `Application`'s `destination.server` would point to a **different cluster's API endpoint** — this is the main YAML change needed |
| **Terraform** | 1 `bootstrap/` project, 1 `terraform.tfvars` | Usually 3 sets of `.tfvars` (or 3 separate Terraform workspaces/state files) — one per project, since `project_id` itself differs per environment |
| **IAM blast radius if compromised** | Limited by namespace RBAC + Kubernetes NetworkPolicy | Limited by GCP's own project boundary — much stronger, since a compromised dev project literally cannot reach prod's resources at the cloud-account level |
| **Cost tracking** | All 3 environments' costs mixed in one GCP billing view | Each environment's cost is cleanly separated automatically — no tagging/labels needed to tell them apart |

### The one thing that would need real, new work

Argo CD's `Application.spec.destination.server` currently says `https://kubernetes.default.svc` (a special shortcut meaning "the same cluster Argo CD itself is running on"). With 3 separate clusters, each external cluster would first need to be registered with Argo CD:

```bash
argocd cluster add <context-name-for-prod-cluster>
```

Then update each environment's `Application` YAML to point `destination.server` at that specific cluster's real API URL instead of the shortcut. Everything else — the Helm chart, the branching, `promote.yml`, the sync policies — stays exactly the same.

### In short

Multi-project setup is **more isolated and more secure by default**, at the cost of **more infrastructure to manage** (multiple clusters, multiple registries, more Terraform state). This project's single-project + namespace-isolation approach is a completely reasonable choice for smaller teams, and everything built here would still make sense as a foundation if it ever needed to grow into the multi-project model later.

---

## 11. Common Problems and Fixes

| Problem | Likely Cause | Fix |
|---|---|---|
| Argo CD pods stuck `Init:0/1`, `CreateContainerError` | Node pool doesn't have enough CPU/memory | Check `kubectl describe nodes \| grep -A5 "Allocated resources"`; either resize the node pool or reduce component resource requests (already tuned down in `argocd.tf`) |
| `Application` shows `resource X is not permitted in project` | The `AppProject`'s allowed-kinds list is missing that Kubernetes kind | Add it to the relevant `argocd-projects/*.yaml` file |
| Promotion workflow fails: tag not found | Typed the tag from memory instead of copying it | Always copy the exact tag from the current environment's `values-*.yaml` |
| `non-fast-forward` git push error in a workflow | Branch name collided with a leftover branch from a previous run | Fixed — `promote.yml` now uses a unique branch name per run (includes the run ID) |
| GitHub Actions can't create a PR ("not permitted") | Repository setting blocks Actions from creating PRs | Repo Settings → Actions → General → enable "Allow GitHub Actions to create and approve pull requests" |
| Cross-repo commit works today, breaks months later | A personal access token silently expired | A GitHub App is used instead — its tokens are generated fresh every run, nothing to expire on a schedule |
| Prod pod ImagePullBackOff | The promoted tag doesn't actually exist yet, or the Artifact Registry repo itself was never created | Confirm the tag exists with `gcloud artifacts docker images describe`; confirm `bootstrap/artifact-registry.tf` was applied |

---

## 12. Interview Questions (With Answers)

**1. What is GitOps, and how is it different from a normal CI/CD pipeline that runs `kubectl apply`?**
GitOps means Git is the single source of truth for what should be running, and a controller (Argo CD) continuously makes the cluster match it. A normal CI/CD pipeline typically runs `kubectl apply` or `helm upgrade` directly from the pipeline, which means the pipeline itself needs cluster credentials, and there's no automatic mechanism correcting the cluster if someone changes something manually afterward. With GitOps, the pipeline never touches the cluster at all — it only ever changes Git, and Argo CD does the actual applying and continuously re-checks that the cluster still matches Git.

**2. Why split application code and deployment config into two repositories?**
Access control, blast radius, and clarity. Application developers only need write access to their own code repo — they never need permission to edit `AppProject` RBAC rules or production sync policies. If the app repo (or one of its dependencies) is ever compromised, the attacker only gets whatever narrow permission that repo's CI identity has (pushing a Docker image) — the cluster, Terraform state, and Argo CD configuration are in a completely separate repo, unreachable from there. Two repos also keep each repo's Git history focused — one on feature work, the other on "what's deployed where."

**3. What is "build once, promote everywhere," and why does rebuilding per environment break that promise?**
It means an image is built exactly once, and that exact same artifact moves through dev → test → prod, with only its reference (tag/digest) changing per environment — never the underlying bytes. Rebuilding separately for each environment, even from identical source code, can produce a subtly different result (a different base-image patch pulled at build time, a different dependency version resolved) — so what got tested is no longer provably the same thing that ships to production.

**4. What's the difference between a Kubernetes `Deployment`'s rolling update and Argo Rollouts' canary strategy?**
A `Deployment`'s rolling update only checks whether the new pod's readiness probe passes, and has no concept of gradually shifting real traffic or pausing for a human/metrics check. An Argo Rollouts canary explicitly controls the update in steps (e.g. 20% → pause → 50% → pause → 100%), with deliberate pauses where a bad release can be caught — and aborted instantly — before it reaches all users.

**5. What is Workload Identity Federation, and why is it safer than a downloaded service account key?**
A downloaded service account key is a long-lived secret — if it leaks, it grants standing access until someone notices and manually revokes it. Workload Identity Federation instead lets GitHub Actions present a short-lived, GitHub-signed OIDC token, which Google Cloud exchanges (only for a specifically trusted repository) for a short-lived GCP access token. Nothing long-lived is stored anywhere, and there's nothing to rotate on a schedule.

**6. Why does prod use manual sync while dev/test use automatic sync?**
Automatic sync (`prune: true, selfHeal: true`) applies every Git change immediately, which is ideal for fast feedback in dev/test. Prod intentionally omits the `automated` block entirely, so Argo CD only ever shows a diff — a human must explicitly run `argocd app sync` after reviewing it. Git remains the single source of truth either way; only the timing of actually applying a change to production requires a deliberate human action.

**7. What is the difference between an Argo CD `Application` and an `AppProject`?**
An `Application` is one specific deployment instruction — which Helm chart/path, from which Git repo and branch, into which namespace. An `AppProject` is the security boundary a group of Applications must operate inside — which repos they may pull from, which destination namespaces they may write to, which Kubernetes resource kinds they're allowed to create, and what RBAC roles exist within that boundary.

**8. What is "App of Apps," and when would you use `ApplicationSet` instead?**
"App of Apps" is a pattern where one root `Application` watches a folder of other `Application` manifests and creates/updates/removes them automatically — full manual control over each one's individual fields (different sync policy, different notification channel, etc). `ApplicationSet` instead uses a generator to stamp out many near-identical Applications from one template automatically. App of Apps fits a small number of genuinely different environments (as in this project); `ApplicationSet` fits many near-identical targets, like dozens of microservices or many customer clusters, where per-target YAML would be pure repetition.

**9. Why use a GitHub App instead of a personal access token for cross-repo automation?**
A fine-grained personal access token is tied to one person's account and GitHub forces it to carry an expiry (maximum one year) — meaning it will eventually stop working on some date nobody's actively tracking, silently breaking the pipeline. A GitHub App is installed independently of any single person's account, and the token it hands to a workflow is generated fresh on every single run (roughly one-hour lifetime, then discarded) from a private key that itself carries no forced expiry — nothing needs to be remembered or rotated on a calendar, and its installation scope is centrally visible and revocable.

**10. If this project moved from one shared GCP project to three separate ones, what would actually need to change?**
The Helm chart, the branching strategy, and `promote.yml`'s retag-never-rebuild logic would all stay exactly the same. What changes: each environment would likely get its own GKE cluster (instead of one cluster with three namespaces), so the `NetworkPolicy`/`ResourceQuota` namespace-isolation setup would no longer be needed — GCP's project boundary provides that isolation instead. Argo CD would typically be installed once, in a dedicated platform project, and registered against the other clusters as external targets (`argocd cluster add`) — meaning each `Application`'s `destination.server` would need to point at that specific cluster's real API endpoint instead of the `https://kubernetes.default.svc` shortcut used today. Terraform would also need separate `.tfvars` (or separate state) per project, since `project_id` itself would differ per environment.
