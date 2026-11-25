# Developer entrypoints. `make help` lists targets.
# These targets validate the repo offline. They do not bake an AMI or apply
# Terraform to AWS.
SHELL := /bin/bash
.DEFAULT_GOAL := help

TF_DIRS := terraform/envs/dev terraform/envs/prod terraform/bootstrap
PKR_DIRS := packer/rhel9 packer/windows2022

.PHONY: help fmt tf-fmt tf-validate tflint checkov packer-fmt packer-validate \
        ansible-lint yamllint gitleaks gate-test scan ci

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

fmt: tf-fmt packer-fmt ## Format Terraform and Packer

tf-fmt: ## terraform fmt (recursive)
	terraform fmt -recursive terraform

tf-validate: ## terraform init (no backend) + validate
	@for d in $(TF_DIRS); do echo "== $$d"; terraform -chdir=$$d init -backend=false -input=false >/dev/null && terraform -chdir=$$d validate || exit 1; done

tflint: ## TFLint (recursive, AWS ruleset)
	cd terraform && tflint --init --config=$$PWD/.tflint.hcl && tflint --recursive --config=$$PWD/.tflint.hcl --format=compact

checkov: ## Checkov: Terraform, GitHub Actions, secrets
	checkov -d . --config-file .checkov.yaml

packer-fmt: ## packer fmt
	packer fmt -recursive packer

packer-validate: ## packer init + validate with a placeholder AMI (no AWS)
	@for d in $(PKR_DIRS); do echo "== $$d"; packer init $$d >/dev/null && packer validate -var source_ami=ami-0123456789abcdef0 $$d || exit 1; done

ansible-lint: ## ansible-lint + yamllint
	yamllint -c .yamllint.yml ansible
	ansible-lint ansible

yamllint: ## YAML lint for ansible/
	yamllint -c .yamllint.yml ansible

gitleaks: ## Secret scan of git history
	gitleaks git --config .gitleaks.toml --redact -v .

gate-test: ## Unit-test the OpenSCAP CAT I gate against a fixture
	python3 scripts/gate-oscap.py scripts/testdata/oscap-results-pass.xml /tmp/oscap-summary-pass.txt
	@echo "pass fixture ok"
	@python3 scripts/gate-oscap.py scripts/testdata/oscap-results-fail.xml /tmp/oscap-summary-fail.txt; \
	  test $$? -eq 10 && echo "fail fixture ok"

scan: tf-fmt tf-validate tflint packer-fmt packer-validate ansible-lint gitleaks ## IaC + Packer + Ansible + secrets

ci: scan checkov gate-test ## Everything CI runs that works offline
