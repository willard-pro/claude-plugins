#!/usr/bin/env bash
# ── grill-seal.sh ─────────────────────────────────────────────────────────────
# Intent seal generation and verification for the grill-me readiness gate.
#
# Hash canonicalisation: every byte from offset 0 up to and including the
# newline terminating the line immediately preceding the `**Content-Hash:**`
# line. Consequently all other seal fields (Readiness, Recommendation, etc.)
# fall inside the hashed region.
#
# The Content-Hash line MUST be the last non-empty line of the file.
# Trailing whitespace after the hash line is ignored by verification.
#
# Exports:
#   grill_seal_generate  <doc-path> <profile-id> <readiness> <recommendation> <rounds> <generated-iso>
#     Appends an ## Intent Seal block. Refuses to seal an already-sealed file.
#
#   grill_seal_verify  <doc-path>
#     Exit 0 VALID, 2 missing/unreadable, 3 NO_SEAL, 4 MISMATCH.
#     Emits GRILL_SEAL_STATUS, GRILL_READINESS, GRILL_RECOMMENDATION,
#     GRILL_PROFILE, GRILL_GENERATED as KEY=value on stdout.
# ───────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── grill_seal_generate ───────────────────────────────────────────────────────
grill_seal_generate() {
  local doc_path="$1"
  local profile="$2"
  local readiness="$3"
  local recommendation="$4"
  local rounds="$5"
  local generated="$6"

  if [ ! -f "$doc_path" ]; then
    echo "grill-seal: document not found: ${doc_path}" >&2
    return 2
  fi

  # Refuse to seal an already-sealed file
  if grep -q '^## Intent Seal$' "$doc_path" 2>/dev/null; then
    echo "grill-seal: document already contains an Intent Seal — refusing to double-seal" >&2
    return 1
  fi

  # Ensure file ends with exactly one newline
  sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$doc_path" 2>/dev/null || true
  # Simpler: ensure there's a trailing newline by appending one, then clean up
  # Actually, let's ensure the file ends with a single newline for clean canonicalization.
  # We'll append the seal to the file as-is, then hash.

  # Append the seal block (without Content-Hash first, to compute the hash)
  local seal_block
  seal_block=$(
    cat <<EOF

## Intent Seal

**Grill-Version:** 0.1.0
**Profile:** ${profile}
**Readiness:** ${readiness}
**Recommendation:** ${recommendation}
**Rounds:** ${rounds}
**Generated:** ${generated}
**Content-Hash:**
EOF
  )

  # Write seal placeholder
  printf '%s' "$seal_block" >>"$doc_path"

  # Compute hash over bytes 0 through the newline before Content-Hash
  # The hash input is everything up to and including the newline that
  # terminates the line immediately before **Content-Hash:**.
  # Since Content-Hash is the last line with empty value, we hash up to
  # the newline ending the `**Generated:**` line.
  local hash_input end_byte
  # Find the byte offset of "**Content-Hash:**"
  local ch_line_num
  ch_line_num=$(grep -n '^\*\*Content-Hash:\*\*$' "$doc_path" | tail -1 | cut -d: -f1)

  if [ -z "$ch_line_num" ]; then
    echo "grill-seal: failed to locate Content-Hash line" >&2
    return 1
  fi

  # Hash everything up to and including the line before Content-Hash
  local prev_line=$((ch_line_num - 1))
  # Get byte count through the end of the previous line
  end_byte=$(head -n "$prev_line" "$doc_path" | wc -c)

  # Compute SHA-256
  local hash_val
  hash_val=$(head -c "$end_byte" "$doc_path" | sha256sum | cut -d' ' -f1)

  # Replace the placeholder Content-Hash line with the actual hash
  local tmp="${doc_path}.tmp.$$"
  sed "s/^\*\*Content-Hash:\*\*$/**Content-Hash:** sha256:${hash_val}/" "$doc_path" >"$tmp"
  mv "$tmp" "$doc_path"

  echo "grill-seal: seal generated for ${doc_path} (readiness=${readiness}, rec=${recommendation})" >&2
  return 0
}

# ── grill_seal_verify ─────────────────────────────────────────────────────────
grill_seal_verify() {
  local doc_path="$1"

  # Exit 2: missing or unreadable file
  if [ ! -f "$doc_path" ]; then
    echo "grill-seal: file not found: ${doc_path}" >&2
    return 2
  fi
  if [ ! -r "$doc_path" ]; then
    echo "grill-seal: file not readable: ${doc_path}" >&2
    return 2
  fi

  # Locate the Content-Hash line
  local ch_line
  ch_line=$(grep -n '^\*\*Content-Hash:\*\* sha256:[a-f0-9]\{64\}$' "$doc_path" | tail -1)

  # Exit 3: no valid seal
  if [ -z "$ch_line" ]; then
    # Check if there's any Intent Seal block at all
    if grep -q '^## Intent Seal$' "$doc_path" 2>/dev/null; then
      echo "grill-seal: Intent Seal present but Content-Hash is malformed" >&2
    else
      echo "grill-seal: no Intent Seal block found" >&2
    fi
    echo "GRILL_SEAL_STATUS=NO_SEAL"
    return 3
  fi

  local ch_line_num
  ch_line_num=$(echo "$ch_line" | cut -d: -f1)

  # Extract recorded hash
  local recorded_hash
  recorded_hash=$(echo "$ch_line" | sed 's/.*sha256://')

  # The hash covers bytes 0 through the newline terminating the line BEFORE Content-Hash
  local prev_line=$((ch_line_num - 1))
  local end_byte
  end_byte=$(head -n "$prev_line" "$doc_path" | wc -c)

  # Recompute
  local computed_hash
  computed_hash=$(head -c "$end_byte" "$doc_path" | sha256sum | cut -d' ' -f1)

  if [ "$computed_hash" != "$recorded_hash" ]; then
    echo "GRILL_SEAL_STATUS=MISMATCH"
    return 4
  fi

  # Extract metadata from seal — seal block is at end of file, scan from ## Intent Seal to EOF
  local seal_readiness seal_rec seal_profile seal_generated
  seal_readiness=$(sed -n '/^## Intent Seal$/,$s/^\*\*Readiness:\*\* //p' "$doc_path" | head -1)
  seal_rec=$(sed -n '/^## Intent Seal$/,$s/^\*\*Recommendation:\*\* //p' "$doc_path" | head -1)
  seal_profile=$(sed -n '/^## Intent Seal$/,$s/^\*\*Profile:\*\* //p' "$doc_path" | head -1)
  seal_generated=$(sed -n '/^## Intent Seal$/,$s/^\*\*Generated:\*\* //p' "$doc_path" | head -1)

  echo "GRILL_SEAL_STATUS=VALID"
  echo "GRILL_READINESS=${seal_readiness}"
  echo "GRILL_RECOMMENDATION=${seal_rec}"
  echo "GRILL_PROFILE=${seal_profile}"
  echo "GRILL_GENERATED=${seal_generated}"

  return 0
}

# If executed directly
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ $# -lt 2 ]; then
    echo "Usage:" >&2
    echo "  grill-seal.sh generate <doc> <profile> <readiness> <rec> <rounds> <generated>" >&2
    echo "  grill-seal.sh verify <doc>" >&2
    exit 1
  fi

  case "$1" in
  generate)
    shift
    grill_seal_generate "$@"
    ;;
  verify)
    shift
    grill_seal_verify "$@"
    ;;
  *)
    echo "grill-seal: unknown command '$1' — use generate or verify" >&2
    exit 1
    ;;
  esac
fi
