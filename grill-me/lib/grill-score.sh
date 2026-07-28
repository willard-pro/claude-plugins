#!/usr/bin/env bash
# ── grill-score.sh ────────────────────────────────────────────────────────────
# Deterministic readiness scoring engine for the grill-me readiness gate.
#
# The agent produces an assessment JSON with judgement only (present|partial|missing
# per dimension, with evidence and gap text). This script computes the readiness
# score, recommendation tier, and ranked questions — entirely in bash, using jq
# for JSON processing. The agent SHALL NOT contain a computed score.
#
# Exports:
#   grill_score  <assessment-json> <profile-json> [result-file]
#     Validate assessment, compute score, emit KEY=value lines and result.json.
#
# Output:
#   stdout:  KEY=value lines for GRILL_READINESS, GRILL_RECOMMENDATION,
#            GRILL_CRITICAL_MISSING, GRILL_FLAGS, GRILL_QUESTION_COUNT
#   file:    result.json (if path provided)
#
# Environment overrides (take precedence over profile values):
#   GRILL_THRESHOLD_READY  — override profile's ready threshold
#   GRILL_THRESHOLD_WARN   — override profile's warn threshold
#   GRILL_MAX_QUESTIONS    — override profile's max_questions
# ───────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Internal: impact rank for question tie-breaking ──────────────────────────
_impact_rank() {
  case "$1" in
  high) echo "3" ;;
  medium) echo "2" ;;
  low) echo "1" ;;
  *) echo "0" ;;
  esac
}

# ── grill_score ───────────────────────────────────────────────────────────────
# Usage: grill_score <assessment-json-file-or-string> <profile-json-file> [result-path]
#
# Reads assessment from stdin if first arg is "-", otherwise treats it as a file
# path or JSON string. Writes result.json to result-path if provided.
# Emits KEY=value lines on stdout.
# ──────────────────────────────────────────────────────────────────────────────
grill_score() {
  local assessment_input="$1"
  local profile_path="$2"
  local result_path="${3:-}"

  # ── Load profile ──────────────────────────────────────────────────────────
  local profile
  profile=$(cat "$profile_path")

  # ── Load assessment ───────────────────────────────────────────────────────
  local assessment
  if [ "$assessment_input" = "-" ]; then
    assessment=$(cat)
  elif [ -f "$assessment_input" ]; then
    assessment=$(cat "$assessment_input")
  else
    # Treat as inline JSON string
    assessment="$assessment_input"
  fi

  # Validate assessment is parseable JSON
  if ! echo "$assessment" | jq '.' >/dev/null 2>&1; then
    echo "grill-score: assessment is not valid JSON" >&2
    return 1
  fi

  # ── Derive effective thresholds ────────────────────────────────────────────
  local ready_threshold warn_threshold max_questions
  ready_threshold="${GRILL_THRESHOLD_READY:-$(echo "$profile" | jq -r '.thresholds.ready')}"
  warn_threshold="${GRILL_THRESHOLD_WARN:-$(echo "$profile" | jq -r '.thresholds.warn')}"
  max_questions="${GRILL_MAX_QUESTIONS:-$(echo "$profile" | jq -r '.max_questions')}"

  # Validate integer types
  if ! [ "$ready_threshold" -ge 0 ] 2>/dev/null; then
    echo "grill-score: invalid ready threshold: ${ready_threshold}" >&2
    return 1
  fi
  if ! [ "$warn_threshold" -ge 0 ] 2>/dev/null; then
    echo "grill-score: invalid warn threshold: ${warn_threshold}" >&2
    return 1
  fi
  if ! [ "$max_questions" -ge 0 ] 2>/dev/null; then
    echo "grill-score: invalid max_questions: ${max_questions}" >&2
    return 1
  fi

  # Validate threshold ordering
  if [ "$warn_threshold" -ge "$ready_threshold" ]; then
    echo "grill-score: warn threshold (${warn_threshold}) must be < ready threshold (${ready_threshold})" >&2
    return 1
  fi

  # ── Collect profile dimension data ─────────────────────────────────────────
  local dim_ids dim_weights dim_criticals dim_order
  dim_ids=()
  dim_weights=()
  dim_criticals=()
  dim_order=()
  local dim_count
  dim_count=$(echo "$profile" | jq '.dimensions | length')

  local i
  for i in $(seq 0 $((dim_count - 1))); do
    dim_ids[$i]=$(echo "$profile" | jq -r ".dimensions[$i].id")
    dim_weights[$i]=$(echo "$profile" | jq -r ".dimensions[$i].weight")
    dim_criticals[$i]=$(echo "$profile" | jq -r ".dimensions[$i].critical")
    dim_order[$i]="$i"
  done

  # Build profile id→index map
  declare -A profile_dim_idx
  for i in $(seq 0 $((dim_count - 1))); do
    profile_dim_idx["${dim_ids[$i]}"]="$i"
  done

  # ── Validate assessment dimensions ─────────────────────────────────────────
  local assessment_dim_ids assessment_statuses assessment_evidences assessment_gaps
  assessment_dim_ids=()
  assessment_statuses=()
  assessment_evidences=()
  assessment_gaps=()

  local a_dim_count
  a_dim_count=$(echo "$assessment" | jq '.dimensions | length')

  local j
  for j in $(seq 0 $((a_dim_count - 1))); do
    local aid astatus aevidence agap
    aid=$(echo "$assessment" | jq -r ".dimensions[$j].id // empty")
    astatus=$(echo "$assessment" | jq -r ".dimensions[$j].status // empty")
    aevidence=$(echo "$assessment" | jq -r ".dimensions[$j].evidence // \"\"")
    agap=$(echo "$assessment" | jq -r ".dimensions[$j].gap // \"\"")

    # Reject unknown dimension ids
    if [ -z "${profile_dim_idx[$aid]:-}" ]; then
      echo "grill-score: assessment references unknown dimension id '${aid}'" >&2
      return 1
    fi

    # Reject status outside present|partial|missing
    case "$astatus" in
    present | partial | missing) ;;
    *)
      echo "grill-score: dimension '${aid}' has invalid status '${astatus}' (must be present|partial|missing)" >&2
      return 1
      ;;
    esac

    assessment_dim_ids[$j]="$aid"
    assessment_statuses[$j]="$astatus"
    assessment_evidences[$j]="$aevidence"
    assessment_gaps[$j]="$agap"
  done

  # ── Build effective status map and detect coerced omissions ────────────────
  declare -A effective_status
  for i in $(seq 0 $((dim_count - 1))); do
    effective_status["${dim_ids[$i]}"]="missing"
  done

  for j in $(seq 0 $((a_dim_count - 1))); do
    effective_status["${assessment_dim_ids[$j]}"]="${assessment_statuses[$j]}"
  done

  # Warn about omitted profile dimensions
  for i in $(seq 0 $((dim_count - 1))); do
    local did="${dim_ids[$i]}"
    local found=0
    for j in $(seq 0 $((a_dim_count - 1))); do
      if [ "${assessment_dim_ids[$j]}" = "$did" ]; then
        found=1
        break
      fi
    done
    if [ "$found" -eq 0 ]; then
      echo "grill-score: profile dimension '${did}' not in assessment — coerced to missing" >&2
    fi
  done

  # ── Compute readiness ──────────────────────────────────────────────────────
  local readiness=0

  for i in $(seq 0 $((dim_count - 1))); do
    local did="${dim_ids[$i]}"
    local weight="${dim_weights[$i]}"
    local status="${effective_status[$did]}"

    local factor
    case "$status" in
    present) factor=1.0 ;;
    partial) factor=0.5 ;;
    missing) factor=0.0 ;;
    esac

    # Use bc for floating-point, but we know weights are integers and factors
    # are 1.0/0.5/0.0, so we can compute with integer arithmetic:
    # contribution = weight * factor (make it an integer-friendly calc)
    case "$status" in
    present) readiness=$((readiness + weight)) ;;
    partial) readiness=$((readiness + (weight / 2))) ;;
    missing) ;; # adds 0
    esac
  done

  # Note: integer division truncates — weight of 1 with partial gives 0.5→0.
  # To be exact, we should track half-units. Let's use an internal scale of 2.
  # Actually, let's recompute with full precision using bash integer trick.
  # We'll track readiness in half-weight units (×2), then round at the end.
  # Recompute:
  local readiness_x2=0
  for i in $(seq 0 $((dim_count - 1))); do
    local did="${dim_ids[$i]}"
    local weight="${dim_weights[$i]}"
    local status="${effective_status[$did]}"

    case "$status" in
    present) readiness_x2=$((readiness_x2 + weight * 2)) ;; # ×2 for precision
    partial) readiness_x2=$((readiness_x2 + weight)) ;;     # weight*1 = half of weight*2
    missing) ;;                                             # adds 0
    esac
  done

  # ── Validate assessment flags ─────────────────────────────────────────────
  local flag_penalty_total=0
  local raised_flags=""
  local worst_flag_cap="" # lowest-tier cap among raised flags

  local profile_flags
  profile_flags=$(echo "$profile" | jq -r '.flags // {} | keys[]' 2>/dev/null || true)

  local assessment_flags
  assessment_flags=$(echo "$assessment" | jq -r '.flags // {} | to_entries[] | select(.value == true) | .key' 2>/dev/null || true)

  for flag_id in $assessment_flags; do
    local pflag_penalty pflag_cap
    pflag_penalty=$(echo "$profile" | jq -r ".flags[\"${flag_id}\"].penalty // 0")
    pflag_cap=$(echo "$profile" | jq -r ".flags[\"${flag_id}\"].cap // \"\"")

    # Validate flag exists in profile
    local flag_exists
    flag_exists=$(echo "$profile" | jq -r ".flags[\"${flag_id}\"] != null")
    if [ "$flag_exists" != "true" ]; then
      echo "grill-score: assessment raises unknown flag '${flag_id}'" >&2
      return 1
    fi

    flag_penalty_total=$((flag_penalty_total + pflag_penalty))

    if [ -n "$raised_flags" ]; then
      raised_flags="${raised_flags},${flag_id}"
    else
      raised_flags="$flag_id"
    fi

    # Track worst cap (lowest tier)
    if [ -n "$pflag_cap" ] && [ "$pflag_cap" != "null" ]; then
      case "$pflag_cap" in
      do-not-proceed)
        worst_flag_cap="do-not-proceed" # lowest possible
        ;;
      proceed-with-warnings)
        if [ "$worst_flag_cap" != "do-not-proceed" ]; then
          worst_flag_cap="proceed-with-warnings"
        fi
        ;;
      esac
    fi
  done

  # Apply penalties: readiness = (score_x2 - penalty_x2) / 2, clamped
  local penalised_x2=$((readiness_x2 - flag_penalty_total * 2))
  if [ "$penalised_x2" -lt 0 ]; then
    penalised_x2=0
  fi
  if [ "$penalised_x2" -gt 200 ]; then
    penalised_x2=200
  fi

  # Readiness as integer 0–100
  readiness=$((penalised_x2 / 2))

  # ── Determine recommendation ───────────────────────────────────────────────
  local recommendation
  local critical_missing=""

  # Check critical dimensions
  for i in $(seq 0 $((dim_count - 1))); do
    local did="${dim_ids[$i]}"
    if [ "${dim_criticals[$i]}" = "true" ] && [ "${effective_status[$did]}" = "missing" ]; then
      if [ -n "$critical_missing" ]; then
        critical_missing="${critical_missing},${did}"
      else
        critical_missing="$did"
      fi
    fi
  done

  if [ -n "$critical_missing" ]; then
    recommendation="do-not-proceed"
    # 2. readiness below warn
  elif [ "$readiness" -lt "$warn_threshold" ]; then
    recommendation="do-not-proceed"
    # 3. readiness below ready
  elif [ "$readiness" -lt "$ready_threshold" ]; then
    recommendation="proceed-with-warnings"
    # 4. ready — may be downgraded by flag cap
  else
    recommendation="ready"
    if [ -n "$worst_flag_cap" ]; then
      recommendation="$worst_flag_cap"
    fi
  fi

  # ── Validate assessment questions ──────────────────────────────────────────
  local raw_questions
  raw_questions=$(echo "$assessment" | jq -c '.questions // []' 2>/dev/null || echo '[]')

  local q_count
  q_count=$(echo "$raw_questions" | jq 'length')

  local qi
  for qi in $(seq 0 $((q_count - 1))); do
    local q_text q_dim q_impact q_why
    q_text=$(echo "$raw_questions" | jq -r ".[$qi].text // empty")
    q_dim=$(echo "$raw_questions" | jq -r ".[$qi].dimension // empty")
    q_impact=$(echo "$raw_questions" | jq -r ".[$qi].impact // empty")
    q_why=$(echo "$raw_questions" | jq -r ".[$qi].why // empty")

    # Reject question without rationale
    if [ -z "$q_why" ]; then
      echo "grill-score: question[$qi] missing non-empty 'why' field" >&2
      return 1
    fi

    # Reject question without target dimension
    if [ -z "$q_dim" ] || [ -z "${profile_dim_idx[$q_dim]:-}" ]; then
      echo "grill-score: question[$qi] has missing or unknown dimension '${q_dim}'" >&2
      return 1
    fi

    # Reject question without text
    if [ -z "$q_text" ]; then
      echo "grill-score: question[$qi] missing 'text' field" >&2
      return 1
    fi
  done

  # ── Rank questions ─────────────────────────────────────────────────────────
  # For each question, compute rank key: weight * (1 - status_factor), impact,
  # profile dimension position, assessment position.
  # Output as tab-separated lines, sort, then take top N.
  local rank_lines=""
  for qi in $(seq 0 $((q_count - 1))); do
    local q_dim q_impact
    q_dim=$(echo "$raw_questions" | jq -r ".[$qi].dimension")
    q_impact=$(echo "$raw_questions" | jq -r ".[$qi].impact // \"low\"")

    local didx="${profile_dim_idx[$q_dim]}"
    local dw="${dim_weights[$didx]}"
    local ds="${effective_status[$q_dim]}"

    # Compute rank score: weight * (1 - status_factor) → higher = more missing
    # For present: 0, partial: weight * 0.5, missing: weight * 1.0
    local rank_score
    case "$ds" in
    present) rank_score=0 ;;
    partial) rank_score="$dw" ;; # weight * 0.5 — but since we all have same 2× scale, just use weight
    missing) rank_score=$((dw * 2)) ;;
    esac

    local imp_rank
    imp_rank=$(_impact_rank "$q_impact")

    rank_lines="${rank_lines}${rank_score}\t${imp_rank}\t${didx}\t${qi}\n"
  done

  # Sort: rank_score descending, impact descending, dim_order ascending, qi ascending
  local ranked_indices
  ranked_indices=$(echo -e "$rank_lines" | sort -t$'\t' -k1,1nr -k2,2nr -k3,3n -k4,4n | awk -F'\t' '{print $4}')

  # Truncate to max_questions
  local truncated_indices=""
  local emitted_count=0
  for idx in $ranked_indices; do
    if [ "$emitted_count" -ge "$max_questions" ]; then
      break
    fi
    if [ -n "$truncated_indices" ]; then
      truncated_indices="${truncated_indices} ${idx}"
    else
      truncated_indices="$idx"
    fi
    emitted_count=$((emitted_count + 1))
  done

  # Build ranked questions JSON array
  local ranked_questions_json="["
  local first_q=1
  for idx in $truncated_indices; do
    local q_json
    q_json=$(echo "$raw_questions" | jq -c ".[$idx]")
    if [ "$first_q" -eq 1 ]; then
      ranked_questions_json="${ranked_questions_json}${q_json}"
      first_q=0
    else
      ranked_questions_json="${ranked_questions_json},${q_json}"
    fi
  done
  ranked_questions_json="${ranked_questions_json}]"

  # ── Build result.json ──────────────────────────────────────────────────────
  local now_iso
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local profile_id
  profile_id=$(echo "$profile" | jq -r '.id')

  local subject
  subject=$(echo "$assessment" | jq -r '.subject // ""')

  local assessment_round
  assessment_round=$(echo "$assessment" | jq -r '.round // 1')

  # Build category scores
  local cat_scores="["
  local first_cat=1
  for i in $(seq 0 $((dim_count - 1))); do
    local did="${dim_ids[$i]}"
    local dlabel dweight
    dlabel=$(echo "$profile" | jq -r ".dimensions[$i].label")
    dweight="${dim_weights[$i]}"
    local dstatus="${effective_status[$did]}"

    local contrib
    case "$dstatus" in
    present) contrib="$dweight" ;;
    partial) contrib=$((dweight / 2)) ;;
    missing) contrib=0 ;;
    esac

    if [ "$first_cat" -eq 1 ]; then
      cat_scores="${cat_scores}{\"dimension\":\"${did}\",\"label\":\"${dlabel}\",\"weight\":${dweight},\"status\":\"${dstatus}\",\"contribution\":${contrib}}"
      first_cat=0
    else
      cat_scores="${cat_scores},{\"dimension\":\"${did}\",\"label\":\"${dlabel}\",\"weight\":${dweight},\"status\":\"${dstatus}\",\"contribution\":${contrib}}"
    fi
  done
  cat_scores="${cat_scores}]"

  local result_json
  result_json=$(
    cat <<JSON
{
  "profile": "${profile_id}",
  "subject": ${subject:+$(echo "$subject" | jq -R '.')},
  "round": ${assessment_round},
  "readiness": ${readiness},
  "recommendation": "${recommendation}",
  "critical_missing": "${critical_missing}",
  "flags": "${raised_flags}",
  "question_count": ${emitted_count},
  "thresholds": {
    "ready": ${ready_threshold},
    "warn": ${warn_threshold}
  },
  "max_questions": ${max_questions},
  "dimensions": ${cat_scores},
  "questions": ${ranked_questions_json},
  "scored_at": "${now_iso}"
}
JSON
  )

  # ── Write result.json if path provided ─────────────────────────────────────
  if [ -n "$result_path" ]; then
    mkdir -p "$(dirname "$result_path")" 2>/dev/null || true
    echo "$result_json" >"$result_path"
  fi

  # ── Emit KEY=value lines ──────────────────────────────────────────────────
  echo "GRILL_READINESS=${readiness}"
  echo "GRILL_RECOMMENDATION=${recommendation}"
  echo "GRILL_CRITICAL_MISSING=${critical_missing}"
  echo "GRILL_FLAGS=${raised_flags}"
  echo "GRILL_QUESTION_COUNT=${emitted_count}"

  # Also emit result JSON on stdout for consumers that want it
  # (separated by a marker so callers can parse selectively)
  echo "---RESULT_JSON---"
  echo "$result_json"

  return 0
}

# If executed directly with args, run grill_score
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ $# -lt 2 ]; then
    echo "Usage: grill-score.sh <assessment-file|-|json> <profile-file> [result-path]" >&2
    exit 1
  fi
  grill_score "$1" "$2" "${3:-}"
fi
