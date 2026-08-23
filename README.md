# k8s-github-runner

Self-hosted GitHub Actions runners for `mattjmorrison-homelab`. `k8s-`
prefixed, not `admin-`: this deploys real running pods into the cluster
via ArgoCD, unlike `admin-github`/`admin-openbao`, which only manage
another system's API-level config with no workload of their own.

**Not using Actions Runner Controller (ARC).** This started as an ARC
deployment (vendored charts, values-only, same pattern as
`homelab-cert-manager`/`homelab-external-secrets`), but ARC's runner
registration is fundamentally broken in this cluster — see "Why not
ARC" below for the full story. Replaced with two plain `Deployment`s
that register runners the classic way directly.

## What gets deployed

- `manifests/templates/runner-deployment-amd64.yaml` /
  `runner-deployment-arm64.yaml` — one long-lived `Deployment` per
  architecture, `replicas: 1` each. Not optional to collapse into one:
  a runner executes a job's steps natively in its own pod, unlike
  Woodpecker's Kubernetes backend (a pure orchestrator that dispatches
  each step's pod to whichever architecture that step requests).
  GitHub Actions has no equivalent per-step dispatch — the
  architecture is picked per *job*, via `runs-on:` labels: `k8s-amd64`
  (→ `imac`) or `k8s-arm64` (→ `pi5-8`/`pi5-16`, tolerates the
  `dedicated=pi:NoSchedule` taint).
- `manifests/templates/runner-register-configmap.yaml` — the startup
  script both Deployments run. Registers with GitHub the classic way
  (`config.sh --token`, using the GitHub App credentials below),
  `--ephemeral` so `run.sh` exits cleanly after each job. Since these
  are plain Deployments (`restartPolicy: Always`), Kubernetes
  restarts the container the instant it exits — the script re-runs
  from the top, wipes any leftover `_work`/registration state, and
  registers fresh for the next job. Net effect: one job at a time per
  architecture, fresh registration every cycle, no custom
  listener/poller needed to trigger it — just Kubernetes' own
  restart-on-exit behavior doing the job ARC's controller used to do.

Trade-off versus ARC's ephemeral pods: it's the same pod restarting in
place between jobs, not a brand-new one each time (mitigated by the
explicit cleanup at the top of the script), and only 1 job at a time
per architecture rather than scaling out to `maxRunners`. Homelab-scale
CI doesn't need more than that today.

## Why not ARC

ARC's ephemeral runner flow (JIT config, `--jitconfig`) reliably failed
**100% of the time** in this cluster: the controller registers a
runner, the pod starts, and the runner process exits cleanly within
~2 seconds without ever picking up the job it was created for —
leaving the job stuck `queued` forever, indefinitely.

Ruled out, with evidence, across many rounds of testing: network/DNS/TLS
reachability, MTU, node clock skew (architecturally impossible for the
node this was tested on — its NTP offset was independently confirmed
at 11ms, and containers share the host's wall clock directly), node
resource pressure, stale job leases, `securityContext` differences,
the `:latest` image tag (pinned to a digest — no change), ARC chart
version (`0.14.2` → `0.13.1`, the version immediately before a rewrite
of ARC's internal client library — no change), and GitHub App vs. PAT
authentication (both fail identically, for both native JIT *and* the
override below).

**What actually distinguishes success from failure**: whether the pod
was created and managed by ARC's `EphemeralRunnerSet` controller at
all. Every combination of *(JIT vs. classic registration) × (App vs.
PAT) × (ARC chart version)* run inside an ARC-managed pod failed —
classic registration got further (registration itself succeeded) but
then failed at broker session creation with
`VssOAuthTokenRequestException: The signature is not valid`, on every
retry, persistently, not transiently. Unsetting
`ACTIONS_RUNNER_INPUT_JITCONFIG` (which ARC injects into the pod
regardless of container `command`) didn't help either. Meanwhile,
classic registration run manually in a plain `kubectl run` pod — same
image, same node, same credentials-generation logic — worked every
single time, including a real dispatched job completing in 3 seconds.
The exact mechanism ARC's pod management breaks was never isolated;
what's confirmed is that avoiding ARC's pod management entirely,
while keeping everything else identical, is what fixes it.

## Can `admin-github`'s Terraform create the GitHub App this needs?

**No — confirmed, this isn't a provider gap, it's a GitHub platform
limitation.** There's no API to create a GitHub App at all; registration
is a manual, browser-based action even via GitHub's "app manifest" flow
(which pre-fills the form but still requires a human to click through
it). The `integrations/github` Terraform provider has open, unresolved
feature requests asking for this — not supported today by any tool.
Manual registration stays a required one-time step, same as it was for
`admin-github`'s own repo-admin App.

## Manual step: register the GitHub App

**A separate App from `admin-github`'s repo-admin one** — different,
narrower permission scope, kept separate to preserve least-privilege
rather than one App accumulating every permission this org ever needs.

Register on `mattjmorrison-homelab` (org Settings → Developer settings →
GitHub Apps → New GitHub App):

- **Repository permissions**
  - `Actions`: **Read-only**
  - `Metadata`: **Read-only**
- **Organization permissions**
  - `Self-hosted runners`: **Read and write**
- No other permissions.

Install it on `mattjmorrison-homelab`, all repositories.

## Manual step: OpenBao secret

Three values end up in OpenBao (`kv/homelab/k8s-github-runner/*`
per-key):

- `github_app_id` — the App's numeric ID
- `github_app_installation_id` — the installation's numeric ID
- `github_app_private_key` — the `.pem` generated on the App's settings
  page

Synced into a Kubernetes Secret named `github-runner-app-credentials`
via the usual `SecretStore`/`ExternalSecret` pair, mounted directly
into both runner Deployments (`manifests/templates/external-secret.yaml`).
The registration script signs its own GitHub App JWT from these three
values (openssl, no external dependency) to fetch an installation
token, then a runner registration token — same auth flow ARC's own
controller used, just done in-pod instead of by a controller.

## Not done yet

- The actual pipeline migration — every existing `.woodpecker.yml` across
  every repo with CI today needs rewriting as `.github/workflows/*.yml`.
  Infrastructure here doesn't touch that; it's separate, larger, ongoing
  work.
- No alerting if a runner Deployment's pod gets stuck crash-looping on
  registration (e.g. GitHub App credential expiry/revocation) — would
  currently just silently stop picking up jobs.
