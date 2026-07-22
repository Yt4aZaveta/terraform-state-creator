#!/usr/bin/env make -f

SHELL := /bin/bash
.DEFAULT_GOAL := help

AWS_REGION ?=
WORK_DIR   ?= imported
SERVICES   ?=
RC         ?=

.PHONY: help collect collect-dry discover main-tf main-tf-dump check

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'

collect: ## Scan cloud → local state + main.tf (RC=./c2rc.sh)
	./scripts/collect-aws-state.sh \
		$(if $(RC),--rc $(RC)) \
		$(if $(AWS_REGION),-r $(AWS_REGION)) \
		$(if $(SERVICES),-s $(SERVICES)) \
		-w $(WORK_DIR) \
		--auto-approve

collect-dry: ## Dry-run collect (no API)
	./scripts/collect-aws-state.sh \
		$(if $(RC),--rc $(RC)) \
		-w $(WORK_DIR) \
		-n

discover: ## Only write inventory.json
	./scripts/discover-aws-resources.sh \
		$(if $(RC),--rc $(RC)) \
		$(if $(AWS_REGION),-r $(AWS_REGION)) \
		$(if $(SERVICES),-s $(SERVICES)) \
		-o $(WORK_DIR)/inventory.json

main-tf: ## Rebuild main.tf from local state
	./scripts/state-to-main-tf.sh -w $(WORK_DIR)

main-tf-dump: ## Rebuild main.tf offline from state JSON
	./scripts/state-to-main-tf.sh -w $(WORK_DIR) --dump

check: ## Validate shell scripts
	bash -n scripts/lib/common.sh
	bash -n scripts/discover-aws-resources.sh
	bash -n scripts/collect-aws-state.sh
	bash -n scripts/state-to-main-tf.sh
	bash -n scripts/create-terraform-state.sh
	bash -n scripts/destroy-terraform-state.sh
	@echo "OK"
