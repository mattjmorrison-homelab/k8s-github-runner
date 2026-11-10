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
