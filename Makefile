# aws-account-bootstrap
#
#   make plan  PROFILE=dev                       show what would change (no changes)
#   make apply PROFILE=dev                       create / update the roles
#   make check PROFILE=dev                       read-only policy checks
#   make sso-plan  PROFILE=management            IAM Identity Center permission sets (no changes)
#   make sso-apply PROFILE=management            create / update them
#
# Everything is asked for, and you are offered to save the answers to
# bootstrap.env — so the first run needs no setup and later runs only confirm.
#
# ENV      GitHub environment(s) allowed to deploy into this account, space-separated
# PROFILE  aws-vault profile to run under; omit to use the credentials you already have
# CONFIG   config file (default ./bootstrap.env)
# YES=1    apply without the confirmation prompt

SHELL  := /bin/bash
CONFIG ?= bootstrap.env
ENV    ?=
PROFILE ?=
YES    ?=

# Run AWS-facing commands under aws-vault when PROFILE is given.
AWS_EXEC := $(if $(PROFILE),aws-vault exec $(PROFILE) --,)
RUN      := BOOTSTRAP_ENV=$(abspath $(CONFIG)) BOOTSTRAP_PROFILE=$(PROFILE) $(AWS_EXEC)

.DEFAULT_GOAL := help
.PHONY: help setup plan apply check sso-plan sso-apply outputs examples lint test clean

help: ## Show this help
	@echo "Usage: make <target> [ENV=\"dev\"] [PROFILE=dev] [CONFIG=bootstrap.env]"
	@echo
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[1m%-9s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Examples:"
	@echo "  make plan  PROFILE=dev                         # asks for anything missing"
	@echo "  make apply PROFILE=dev ENV=dev"
	@echo "  make apply PROFILE=prod ENV=\"staging production\""
	@echo "  make check PROFILE=dev"

setup: ## Copy bootstrap.env.example to edit by hand (optional — plan/apply ask instead)
	@if [ -f "$(CONFIG)" ]; then \
	  echo "$(CONFIG) already exists — edit it directly"; \
	else \
	  cp bootstrap.env.example "$(CONFIG)" && echo "created $(CONFIG) — set GITHUB_ORG, PLATFORM_REPOS and APP_REPOS"; \
	fi

plan: ## Show the plan and every policy document; changes nothing
	@$(RUN) ./bootstrap-account.sh --dry-run $(ENV)

apply: ## Create or update the roles in the account
	@$(RUN) ./bootstrap-account.sh $(if $(YES),--yes,) $(ENV)

check: _config ## Validate the policies with Access Analyzer + the IAM simulator (read-only)
	@$(RUN) ./check-policy.sh

sso-plan: ## Show the IAM Identity Center permission sets plan; changes nothing
	@$(AWS_EXEC) ./permission-sets.sh --dry-run

sso-apply: ## Create or update the permission sets (run in the management account)
	@$(AWS_EXEC) ./permission-sets.sh $(if $(YES),--yes,)

outputs: _config ## Re-render outputs/ from the accounts already applied (no AWS)
	@BOOTSTRAP_ENV=$(abspath $(CONFIG)) bash -c 'source lib/config.sh && config_defaults && python3 lib/outputs.py render'

examples: ## Regenerate examples/ (the outputs for two made-up accounts)
	@rm -rf examples && python3 lib/outputs.py sample examples && echo "examples/ regenerated"

lint: ## shellcheck the scripts and validate the policy templates
	@command -v shellcheck >/dev/null || { echo "shellcheck is not installed"; exit 1; }
	shellcheck bootstrap-account.sh check-policy.sh permission-sets.sh lib/config.sh lib/github.sh
	@for f in policies/*.json identity-center/*.json identity-center/policies/*.json; do python3 -m json.tool "$$f" >/dev/null || { echo "invalid JSON: $$f"; exit 1; }; done
	@python3 -m py_compile lib/render.py lib/outputs.py && rm -rf lib/__pycache__
	@echo "lint: ok"

test: lint ## lint, then dry-run with the example config (no AWS needed)
	@BOOTSTRAP_ENV=$(abspath bootstrap.env.example) CONFIGURE_GITHUB=false AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null \
	  ./bootstrap-account.sh --dry-run dev production </dev/null >/dev/null
	@BOOTSTRAP_ENV=$(abspath bootstrap.env.example) CONFIGURE_GITHUB=false APP_REPOS= LAMBDA_ROLE_NAME= \
	  AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null \
	  ./bootstrap-account.sh --dry-run dev </dev/null >/dev/null
	@BOOTSTRAP_ENV=$(abspath bootstrap.env.example) CONFIGURE_GITHUB=false SECURITY_GROUP=yes \
	  AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null \
	  ./bootstrap-account.sh --dry-run dev </dev/null | grep 'Security group app-default-sg' >/dev/null
	@BOOTSTRAP_ENV=$(abspath bootstrap.env.example) CONFIGURE_GITHUB=false \
	  AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null \
	  ./bootstrap-account.sh --dry-run dev </dev/null | { ! grep 'Security group' >/dev/null; }
	@AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true \
	  ./permission-sets.sh --dry-run </dev/null | grep -c '^    create$$' | grep -qx 5 || \
	  { echo "permission-sets.sh --dry-run did not plan all five permission sets"; exit 1; }
	@tmp=$$(mktemp -d) && python3 lib/outputs.py sample "$$tmp" && \
	  { diff -r "$$tmp" examples || { echo "examples/ is stale: run make examples"; rm -rf "$$tmp"; exit 1; }; } && rm -rf "$$tmp"
	@echo "test: ok — the dry runs rendered every document, the security group only when asked for, the five permission sets, examples/ is current"

clean: ## Remove local caches
	rm -rf lib/__pycache__

_config:
	@[ -f "$(CONFIG)" ] || { echo "$(CONFIG) not found — run 'make plan' first (it asks and saves), or pass CONFIG=path"; exit 1; }
