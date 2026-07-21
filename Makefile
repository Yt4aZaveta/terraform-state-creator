#!/usr/bin/env make -f

SHELL := /bin/bash
.DEFAULT_GOAL := help

AWS_REGION      ?= eu-central-1
STATE_BUCKET    ?=
LOCK_TABLE      ?= terraform-state-lock
PROJECT_PREFIX  ?= tfstate
OUTPUT_DIR      ?= generated

.PHONY: help create destroy dry-run example-init example-plan check

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'

create: ## Create S3 + DynamoDB remote state (STATE_BUCKET optional)
	./scripts/create-terraform-state.sh \
		$(if $(STATE_BUCKET),-b $(STATE_BUCKET)) \
		-t $(LOCK_TABLE) \
		-r $(AWS_REGION) \
		-p $(PROJECT_PREFIX) \
		-o $(OUTPUT_DIR)

dry-run: ## Preview create without calling AWS
	./scripts/create-terraform-state.sh \
		$(if $(STATE_BUCKET),-b $(STATE_BUCKET),-b dry-run-example-bucket) \
		-t $(LOCK_TABLE) \
		-r $(AWS_REGION) \
		-p $(PROJECT_PREFIX) \
		-o $(OUTPUT_DIR) \
		--dry-run

destroy: ## Destroy remote state backend (requires STATE_BUCKET=...)
	@test -n "$(STATE_BUCKET)" || (echo "Set STATE_BUCKET=..."; exit 1)
	./scripts/destroy-terraform-state.sh \
		-b $(STATE_BUCKET) \
		-t $(LOCK_TABLE) \
		-r $(AWS_REGION)

example-init: ## terraform init for examples/infra using generated backend
	@test -f $(OUTPUT_DIR)/backend.hcl || (echo "Run make create first"; exit 1)
	cd examples/infra && terraform init -backend-config=../../$(OUTPUT_DIR)/backend.hcl

example-plan: ## terraform plan for examples/infra
	cd examples/infra && terraform plan

check: ## Validate shell scripts (bash -n)
	bash -n scripts/create-terraform-state.sh
	bash -n scripts/destroy-terraform-state.sh
	@echo "OK"
