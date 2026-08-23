.PHONY: create-runner-pat-secret

# Temporary, for isolating whether ARC's JIT flow fails specifically with
# GitHub App auth vs a classic PAT. Needs a PAT with 'admin:org' scope
# (classic) or "Organization permissions: Self-hosted runners: Read and
# write" (fine-grained), from an account that can manage runners on
# mattjmorrison-homelab. Not stored anywhere -- passed via env var only.
#
# Usage: RUNNER_PAT=ghp_xxx make create-runner-pat-secret
create-runner-pat-secret:
	@if [ -z "$(RUNNER_PAT)" ]; then \
		echo "Usage: RUNNER_PAT=ghp_xxx make create-runner-pat-secret"; \
		exit 1; \
	fi
	kubectl create secret generic github-runner-pat-credentials \
		--namespace github-runner \
		--from-literal=github_token=$(RUNNER_PAT) \
		--dry-run=client -o yaml | kubectl apply -f -
