# k8s-github-runner

Self-hosted GitHub Actions runners for `mattjmorrison-homelab`, via
[Actions Runner Controller](https://github.com/actions/actions-runner-controller)
(ARC) — vendored charts, values-only, same pattern as
`homelab-cert-manager`/`homelab-external-secrets`. `k8s-` prefixed, not
`admin-`: this deploys real running pods into the cluster via ArgoCD,
unlike `admin-github`/`admin-openbao`, which only manage another system's
API-level config with no workload of their own.

## What gets deployed — three releases, not one

- `values-controller.yaml` — the ARC controller itself
  (`gha-runner-scale-set-controller`), cluster-wide, one release. Manages
  the `RunnerScaleSet` custom resources the other two releases create.
- `values-runner-amd64.yaml` / `values-runner-arm64.yaml` — two separate
  `gha-runner-scale-set` releases, one per architecture. Not optional to
  collapse into one: a runner executes a job's steps natively in its own
  pod, unlike Woodpecker's Kubernetes backend (a pure orchestrator that
  dispatches each step's pod to whichever architecture that step
  requests). GitHub Actions has no equivalent per-step dispatch — the
  architecture is picked per *job*, via `runs-on:` labels matching a
  scale set's `runnerScaleSetName`: `k8s-amd64` (→ `imac`) or `k8s-arm64`
  (→ `pi5-8`/`pi5-16`, tolerates the `dedicated=pi:NoSchedule` taint).

`minRunners: 0` on both — scales to zero when idle, `maxRunners: 3` as a
reasonable homelab-scale cap.

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
GitHub Apps → New GitHub App), with, confirmed against ARC's own docs for
**organization-scoped** runners specifically (not repository-scoped,
which needs broader `Administration` access this doesn't need):

- **Repository permissions**
  - `Actions`: **Read-only**
  - `Metadata`: **Read-only**
- **Organization permissions**
  - `Self-hosted runners`: **Read and write**
- No other permissions.

Install it on `mattjmorrison-homelab`, all repositories.

## Manual step: OpenBao secret

Three values end up in OpenBao (`kv/homelab/github-runner` — or, if
`admin-openbao` has migrated by the time this is built,
`kv/homelab/k8s-github-runner/*` per-key), matching the exact key names
ARC's own docs specify:

- `github_app_id` — the App's numeric ID
- `github_app_installation_id` — the installation's numeric ID
- `github_app_private_key` — the `.pem` generated on the App's settings
  page

Synced into a Kubernetes Secret named `github-runner-app-credentials` via
the usual `SecretStore`/`ExternalSecret` pair (not built yet — needs a
Kubernetes auth role in OpenBao the same as every other app here).

## Ephemeral runners via ARC were broken — pinned to a known-good version

ARC's ephemeral runner flow (JIT config, `--jitconfig`) reliably failed
100% of the time in this cluster: the controller registers a runner,
the pod starts, and the runner process exits cleanly within ~2 seconds
without ever picking up the job it was created for — leaving the job
stuck `queued` forever. Confirmed via a side-by-side test: a runner
registered the *classic* way (`config.sh --token ...`, no JIT) on the
exact same node/image picked up and completed a real job in 3 seconds,
every time. Ruled out as causes: network/DNS/TLS reachability, MTU,
node clock skew, node resource pressure, stale job leases,
`securityContext` differences, and the `:latest` image tag.

`homelab-apps`' Application sources also had `targetRevision: "*"` for
both the controller and scale-set charts — always floating to
whatever's newest, never actually pinned. Fixed that regardless (now
pinned to `0.13.1`), but confirmed via a controlled re-test that the
chart version itself isn't the cause: JIT registration fails
identically on `0.13.1` as it did on `0.14.2`.

Fix: `manifests/templates/classic-register-configmap.yaml` overrides
the runner container's default entrypoint (`command` in
`values-runner-amd64.yaml`/`values-runner-arm64.yaml`) so it ignores
the JIT config ARC injects and instead does classic token-based
registration — using the same GitHub App credentials ARC's controller
already has (mounted directly into the runner pod), `--ephemeral` so
it still self-deregisters after one job. ARC still owns pod creation,
scheduling, and cleanup; only the runner's own startup registration
path changed. One known open risk: ARC pre-allocates a runner ID via
JIT before the pod starts and may log a harmless mismatch/warning when
it tries to clean up that ID, since the pod registers under a
different one — worth watching for after this deploys.

## Not done yet

- The `SecretStore`/`ExternalSecret`/`ServiceAccount` manifests for the
  above.
- Wiring into `homelab-apps` — three `Application` entries (multi-source,
  same shape as `homelab-cert-manager`'s: an upstream OCI chart source
  plus this repo as the `$values` source), one each for the controller
  and the two runner releases.
- The actual pipeline migration — every existing `.woodpecker.yml` across
  every repo with CI today needs rewriting as `.github/workflows/*.yml`.
  Infrastructure here doesn't touch that; it's separate, larger, ongoing
  work.
