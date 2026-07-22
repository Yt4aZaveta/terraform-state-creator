#!/usr/bin/env make -f

SHELL := /bin/bash
.DEFAULT_GOAL := help

AWS_REGION      ?= eu-central-1
STATE_BUCKET    ?=
LOCK_TABLE      ?= terraform-state-lock
PROJECT_PREFIX  ?= tfstate
OUTPUT_DIR      ?= generated
WORK_DIR        ?= imported
SERVICES        ?= vpc,subnet,route_table,igw,nat,eip,sg,ec2,ebs,s3,rds,dynamodb,lambda,elb

.PHONY: help create destroy dry-run collect collect-dry discover example-init example-plan check

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'

collect: ## Scan AWS + build Terraform state (creds → inventory → import → S3)
	./scripts/collect-aws-state.sh \
		-r $(AWS_REGION) \
		$(if $(STATE_BUCKET),-b $(STATE_BUCKET)) \
		-t $(LOCK_TABLE) \
		-s $(SERVICES) \
		-w $(WORK_DIR) \
		--auto-approve

collect-dry: ## Dry-run collect (no AWS / no terraform apply)
	./scripts/collect-aws-state.sh \
		-r $(AWS_REGION) \
		-b dryrun-tfstate-bucket \
		-t $(LOCK_TABLE) \
		-s $(SERVICES) \
		-w $(WORK_DIR) \
		-n

discover: ## Only scan AWS and write inventory JSON
	./scripts/discover-aws-resources.sh \
		-r $(AWS_REGION) \
		-s $(SERVICES) \
		$(if $(STATE_BUCKET),--skip-bucket $(STATE_BUCKET)) \
		-o $(WORK_DIR)/inventory.json

create: ## Create S3 + DynamoDB remote state only (STATE_BUCKET optional)
	./scripts/create-terraform-state.sh \
		$(if $(STATE_BUCKET),-b $(STATE_BUCKET)) \
		-t $(LOCK_TABLE) \
		-r $(AWS_REGION) \
		-p $(PROJECT_PREFIX) \
		-o $(OUTPUT_DIR)

dry-run: ## Preview backend create without calling AWS
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
	bash -n scripts/lib/common.sh
	bash -n scripts/create-terraform-state.sh
	bash -n scripts/destroy-terraform-state.sh
	bash -n scripts/discover-aws-resources.sh
	bash -n scripts/collect-aws-state.sh
	@echo "OK"
