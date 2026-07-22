#!/usr/bin/env make -f

SHELL := /bin/bash
.DEFAULT_GOAL := help

AWS_REGION ?= eu-central-1
WORK_DIR   ?= imported
SERVICES   ?= vpc,subnet,route_table,igw,nat,eip,sg,ec2,ebs,s3,rds,dynamodb,lambda,elb

.PHONY: help collect collect-dry discover main-tf main-tf-dump check

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'

collect: ## Scan AWS → local state + main.tf
	./scripts/collect-aws-state.sh \
		-r $(AWS_REGION) \
		-s $(SERVICES) \
		-w $(WORK_DIR) \
		--auto-approve

collect-dry: ## Dry-run collect (no AWS / no terraform apply)
	./scripts/collect-aws-state.sh \
		-r $(AWS_REGION) \
		-s $(SERVICES) \
		-w $(WORK_DIR) \
		-n

discover: ## Only scan AWS and write inventory JSON
	./scripts/discover-aws-resources.sh \
		-r $(AWS_REGION) \
		-s $(SERVICES) \
		-o $(WORK_DIR)/inventory.json

main-tf: ## Rebuild main.tf from local state (live generate if AWS available)
	./scripts/state-to-main-tf.sh -w $(WORK_DIR)

main-tf-dump: ## Rebuild main.tf offline from state JSON
	./scripts/state-to-main-tf.sh -w $(WORK_DIR) --dump

check: ## Validate shell scripts (bash -n)
	bash -n scripts/lib/common.sh
	bash -n scripts/discover-aws-resources.sh
	bash -n scripts/collect-aws-state.sh
	bash -n scripts/state-to-main-tf.sh
	bash -n scripts/create-terraform-state.sh
	bash -n scripts/destroy-terraform-state.sh
	@echo "OK"
