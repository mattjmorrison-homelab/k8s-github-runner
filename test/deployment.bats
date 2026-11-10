#!/usr/bin/env bats

setup() {
  cd "$BATS_TEST_DIRNAME/.."
  RENDERED="$(helm template github-runner-test manifests)"
  export RENDERED
}

@test "renders restartTrigger as the amd64 runner pod template's restart-trigger annotation" {
  annotation=$(echo "$RENDERED" | yq eval-all '
    select(.kind == "Deployment" and .metadata.name == "k8s-amd64-runner") | .spec.template.metadata.annotations["restart-trigger"]
  ' -)
  [ "$annotation" = "2026-11-10-recover-stuck-amd64-runners-2" ]
}

@test "pins all three runner deployments to the actions-runner 2.338.2 digest" {
  for name in k8s-amd64-runner k8s-arm64-runner k8s-pi-provision-runner; do
    image=$(echo "$RENDERED" | yq eval-all "
      select(.kind == \"Deployment\" and .metadata.name == \"$name\") | .spec.template.spec.containers[] | select(.name == \"runner\") | .image
    " -)
    [ "$image" = "ghcr.io/actions/actions-runner@sha256:759a1d94a15b05941aba5196974ff43fe15b4cbba29b694b35cbc32a1166b232" ]
  done
}

@test "disables the in-container self-update on all three runner deployments" {
  for name in k8s-amd64-runner k8s-arm64-runner k8s-pi-provision-runner; do
    value=$(echo "$RENDERED" | yq eval-all "
      select(.kind == \"Deployment\" and .metadata.name == \"$name\") | .spec.template.spec.containers[] | select(.name == \"runner\") | .env[] | select(.name == \"DISABLE_RUNNER_UPDATE\") | .value
    " -)
    [ "$value" = "true" ]
  done
}
