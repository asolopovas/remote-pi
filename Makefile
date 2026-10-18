.DEFAULT_GOAL := help
.PHONY: help test-tooling test-launch validate doctor deploy
export EXTENSION_ROOT

help:
	@printf '%s\n' 'make doctor EXTENSION_ROOT=/absolute/extension/root  Read-only runtime diagnosis' 'make test-tooling  Lightweight offline workflow/docs/guard tests' 'make test-launch   Focused launcher checks (run under machine lease)' 'make validate      Full app + relay + extension gate (run under machine lease)' 'make deploy        Gated Android client update only (machine lease; see README)' 'See README.md#development-workflow for prerequisites and scope.'

test-tooling:
	bash scripts/validate.sh tooling

test-launch:
	bash scripts/validate.sh launch

validate:
	bash scripts/validate.sh all

doctor:
	env -u NODE_OPTIONS node scripts/doctor-managed-runtime.mjs

# Android client only; caller must hold the machine lease.
deploy:
	python3 scripts/deploy-android.py
