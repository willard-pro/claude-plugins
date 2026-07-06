SCRIPTS := $(shell find . -name "*.sh" -not -path "./.git/*")

.PHONY: test test-lib test-flow test-kc lint fmt-check fmt

test: test-lib test-flow test-kc

test-lib:
	@echo "=== lib unit tests ==="
	bash ticket-auto-pipeline/lib/tests/test-linear-api.sh
	bash ticket-auto-pipeline/lib/tests/test-env-check.sh
	bash ticket-auto-pipeline/lib/tests/test-notes-parse.sh
	bash ticket-auto-pipeline/lib/tests/test-ticket-dir.sh
	bash ticket-auto-pipeline/lib/tests/test-heartbeat.sh
	bash ticket-auto-pipeline/lib/tests/test-capture-transcript.sh
	bash ticket-auto-pipeline/lib/tests/test-reconcile-comments.sh
	bash ticket-auto-pipeline/lib/tests/test-spawn-helper.sh
	bash ticket-auto-pipeline/lib/tests/test-fleet-detect.sh
	bash ticket-auto-pipeline/lib/tests/test-fleet-intervene.sh
	bash ticket-auto-pipeline/lib/tests/test-fleet-dashboard.sh
	bash ticket-auto-pipeline/lib/tests/test-config.sh
	bash ticket-auto-pipeline/lib/tests/test-fleet-monitor.sh
	bash ticket-auto-pipeline/lib/test-persona-select.sh
	CLAUDE_SKILLS_LIB="$(CURDIR)/ticket-auto-pipeline/lib" \
	bash ticket-auto-pipeline/lib/tests/test-gate-check.sh
	CLAUDE_SKILLS_LIB="$(CURDIR)/ticket-auto-pipeline/lib" \
	bash ticket-auto-pipeline/lib/tests/test-outcome-label-check.sh
	CLAUDE_SKILLS_LIB="$(CURDIR)/ticket-auto-pipeline/lib" \
	bash ticket-auto-pipeline/lib/tests/test-pipeline-phases.sh
	CLAUDE_SKILLS_LIB="$(CURDIR)/ticket-auto-pipeline/lib" \
	bash ticket-auto-pipeline/lib/tests/test-detect-resume.sh
	# ticket-audit tests
	bash ticket-auto-pipeline/lib/tests/test-ticket-audit-split-detection.sh
	bash ticket-auto-pipeline/lib/tests/test-ticket-audit-drift.sh
	bash ticket-auto-pipeline/lib/tests/test-ticket-audit-cache.sh
	bash ticket-auto-pipeline/lib/tests/test-ticket-audit-checklist.sh
	bash ticket-auto-pipeline/lib/tests/test-linear-api-audit.sh
	# ticket-audit-exec tests
	bash ticket-auto-pipeline/lib/tests/test-ticket-audit-exec-resume.sh
	bash ticket-auto-pipeline/lib/tests/test-ticket-audit-exec-phase-gate.sh
	bash ticket-auto-pipeline/lib/tests/test-ticket-audit-exec-dedup.sh
	# prescan tests
	bash ticket-auto-pipeline/lib/tests/test-prescan-check.sh
	bash ticket-auto-pipeline/lib/tests/test-prescan-route.sh
	bash ticket-auto-pipeline/lib/tests/test-index-schema-contract.sh
	bash ticket-auto-pipeline/lib/tests/test-prescan-docs.sh
	# pipeline-integrity tests
	bash ticket-auto-pipeline/lib/tests/test-return-completeness.sh
	bash ticket-auto-pipeline/lib/tests/test-corrections.sh

test-flow:
	@echo "=== ticket-flow tests ==="
	CLAUDE_SKILLS_LIB="$(CURDIR)/ticket-auto-pipeline/lib" bash ticket-auto-pipeline/skills/ticket-flow/tests/phase1.sh
	CLAUDE_SKILLS_LIB="$(CURDIR)/ticket-auto-pipeline/lib" bash ticket-auto-pipeline/skills/ticket-flow/tests/phase2.sh

test-kc:
	@echo "=== knowledge-curator unit tests ==="
	bash knowledge-curator/test/test-kc-index.sh
	bash knowledge-curator/test/test-kc-item.sh
	bash knowledge-curator/test/test-kc-resurface.sh
	bash knowledge-curator/test/test-kc-prompt-match.sh

lint:
	shellcheck -S error $(SCRIPTS)

lint-strict:
	shellcheck $(SCRIPTS)

fmt-check:
	shfmt -i 2 -d $(SCRIPTS)

fmt:
	shfmt -i 2 -w $(SCRIPTS)
