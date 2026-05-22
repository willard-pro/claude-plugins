SCRIPTS := $(shell find . -name "*.sh" -not -path "./.git/*")

.PHONY: test test-lib test-flow lint fmt-check fmt

test: test-lib test-flow

test-lib:
	@echo "=== lib unit tests ==="
	bash ticket-auto-pipeline/lib/tests/test-linear-api.sh
	bash ticket-auto-pipeline/lib/tests/test-env-check.sh
	bash ticket-auto-pipeline/lib/tests/test-notes-parse.sh
	bash ticket-auto-pipeline/lib/tests/test-ticket-dir.sh
	bash ticket-auto-pipeline/lib/tests/test-heartbeat.sh
	bash ticket-auto-pipeline/lib/tests/test-capture-transcript.sh
	bash ticket-auto-pipeline/lib/tests/test-reconcile-comments.sh

test-flow:
	@echo "=== ticket-flow tests ==="
	bash ticket-auto-pipeline/skills/ticket-flow/tests/phase1.sh
	bash ticket-auto-pipeline/skills/ticket-flow/tests/phase2.sh

lint:
	shellcheck -S error $(SCRIPTS)

lint-strict:
	shellcheck $(SCRIPTS)

fmt-check:
	shfmt -d $(SCRIPTS)

fmt:
	shfmt -w $(SCRIPTS)
