.DEFAULT_GOAL := help
PY ?= python
ENV ?= staging
APP ?= sentinel

.PHONY: help
help: ## Show available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: bootstrap
bootstrap: ## Create a kind cluster, install Argo CD, hand it this repo
	./scripts/bootstrap-kind.sh

.PHONY: teardown
teardown: ## Delete the kind cluster
	./scripts/teardown-kind.sh

.PHONY: status
status: ## Sync and health of every application
	$(PY) cli/keel.py status --verbose

.PHONY: drift
drift: ## Desired tags in Git versus running images
	$(PY) cli/keel.py diff

.PHONY: promote
promote: ## Promote a tag: make promote APP=sentinel ENV=staging TAG=sha-abc1234
	@test -n "$(TAG)" || { echo "TAG is required"; exit 1; }
	$(PY) cli/keel.py promote --app $(APP) --env $(ENV) --tag $(TAG) --push

.PHONY: rollback
rollback: ## Roll back: make rollback APP=sentinel ENV=prod
	$(PY) cli/keel.py rollback --app $(APP) --env $(ENV)

.PHONY: timings
timings: ## Deploy and rollback durations from the ledger
	$(PY) cli/keel.py timings --verbose

.PHONY: validate
validate: tf-validate manifests cli-lint shell-lint ## Everything CI checks

.PHONY: tf-validate
tf-validate: ## terraform fmt + validate, root and modules
	cd terraform && terraform fmt -check -recursive
	cd terraform && terraform init -backend=false -input=false && terraform validate
	cd terraform && for m in modules/*/; do \
		terraform -chdir="$$m" init -backend=false -input=false && \
		terraform -chdir="$$m" validate; done

.PHONY: manifests
manifests: ## Schema-check the Argo CD and Rollouts manifests
	kubeconform -strict -summary \
		-schema-location default \
		-schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
		-ignore-missing-schemas \
		gitops/bootstrap gitops/applications rollouts

.PHONY: cli-lint
cli-lint: ## Lint the CLI
	ruff check cli && ruff format --check cli

.PHONY: shell-lint
shell-lint: ## Lint the shell scripts
	shellcheck -x scripts/*.sh

.PHONY: argocd-ui
argocd-ui: ## Port-forward the Argo CD UI and print the admin password
	@echo "http://localhost:8080"
	@kubectl -n argocd get secret argocd-initial-admin-secret \
		-o jsonpath='{.data.password}' 2>/dev/null | base64 -d; echo
	kubectl -n argocd port-forward svc/argocd-server 8080:80

.PHONY: rollout-watch
rollout-watch: ## Watch the Sentinel canary
	kubectl argo rollouts get rollout sentinel-gateway -n sentinel-$(ENV) --watch
