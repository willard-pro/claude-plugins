SCRIPTS := $(shell find . -name "*.sh" -not -path "./.git/*")

.PHONY: test test-lib test-flow test-kc lint fmt-check fmt test-grill test-planner-intent-gate

test: test-lib test-planner test-flow test-kc test-grill test-planner-intent-gate

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
	bash ticket-auto-pipeline/lib/tests/test-error-handler.sh
	bash ticket-auto-pipeline/lib/tests/test-trajectory.sh
	bash ticket-auto-pipeline/lib/tests/test-verifier-result.sh
	bash ticket-auto-pipeline/lib/tests/test-pipeline-postmortem.sh
	# fleet-controller tests
	bash fleet-controller/lib/tests/test-fleet-detect.sh
	bash fleet-controller/lib/tests/test-fleet-detect-new.sh
	bash fleet-controller/lib/tests/test-fleet-intervene.sh
	bash fleet-controller/lib/tests/test-fleet-dashboard.sh
	bash fleet-controller/lib/tests/test-fleet-dispatch.sh
	bash fleet-controller/lib/tests/test-fleet-feedback.sh
	bash fleet-controller/lib/tests/test-fleet-monitor.sh
	bash fleet-controller/lib/tests/test-fleet-monitor-dispatch.sh
	# ticket-planner enrichment tests
	bash ticket-auto-pipeline/lib/tests/test-planned-ticket-check.sh
	bash ticket-auto-pipeline/lib/tests/test-appraise-fast-path.sh
	bash ticket-auto-pipeline/lib/tests/test-template-select.sh
	bash ticket-auto-pipeline/lib/tests/test-planner-artifacts.sh
	bash ticket-auto-pipeline/lib/tests/test-planned-body-check.sh
	bash ticket-auto-pipeline/lib/tests/test-appraise-exec-planned.sh
	CLAUDE_SKILLS_LIB="$(CURDIR)/ticket-auto-pipeline/lib" \
	bash ticket-auto-pipeline/lib/tests/test-gate-no-template.sh
	bash ticket-auto-pipeline/lib/tests/test-state-machine-labels.sh
	bash ticket-auto-pipeline/lib/tests/test-config.sh
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
	# retro GitHub issues tests
	bash ticket-auto-pipeline/lib/tests/test-github-issues.sh
	# shared-branch programme tests (Phases 1-3)
	bash ticket-auto-pipeline/lib/tests/test-branch-directive-check.sh
	bash ticket-auto-pipeline/lib/tests/test-branch-resolve.sh
	bash ticket-auto-pipeline/lib/tests/test-worktree.sh
	bash ticket-auto-pipeline/lib/tests/test-epic-branch.sh

test-planner:
	@echo "=== ticket-planner unit tests ==="
	bash ticket-planner/lib/tests/test-planner-sanitize.sh
	bash ticket-planner/lib/tests/test-planner-state.sh
	bash ticket-planner/lib/tests/test-planner-transitions.sh
	bash ticket-planner/lib/tests/test-planner-generation.sh
	bash ticket-planner/lib/tests/test-planner-replan.sh
	bash ticket-planner/lib/tests/test-planner-integration.sh
	bash ticket-planner/lib/tests/test-branch-decision.sh
	bash ticket-planner/lib/tests/test-branch-directive-gen.sh

test-planner-intent-gate:
	@echo "=== planner intent gate tests ==="
	bash ticket-planner/lib/tests/test-planner-intent-gate.sh

test-grill:
	@echo "=== grill-me unit tests ==="
	bash grill-me/lib/tests/test-grill-profile.sh
	bash grill-me/lib/tests/test-grill-score.sh
	bash grill-me/lib/tests/test-grill-seal.sh
	bash grill-me/lib/tests/test-grill-render.sh

test-flow:
	@echo "=== ticket-flow tests ==="
	CLAUDE_SKILLS_LIB="$(CURDIR)/ticket-auto-pipeline/lib" bash ticket-auto-pipeline/skills/ticket-flow/tests/phase1.sh
	CLAUDE_SKILLS_LIB="$(CURDIR)/ticket-auto-pipeline/lib" bash ticket-auto-pipeline/skills/ticket-flow/tests/phase2.sh

test-kc:
	@echo "=== knowledge-curator unit tests ==="
	bash knowledge-curator/test/test-kc-index.sh
	bash knowledge-curator/test/test-kc-item.sh
	bash knowledge-curator/test/test-kc-render.sh
	bash knowledge-curator/test/test-kc-rank-log.sh
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
