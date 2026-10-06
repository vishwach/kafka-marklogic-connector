#!/usr/bin/env bash
#
# Snapshots every resolved version of a dependency group across all Gradle configurations so a
# security fix can be proven "before" and "after".
#
# Usage:
#   .github/scripts/capture-dependency-evidence.sh <group> <label> [min-version]
#
#   group        Maven group id to report on, e.g. io.netty
#   label        Free-form tag for the snapshot, e.g. before | after
#   min-version  Optional. When given, the script exits non-zero if any resolved artifact in the
#                group is older than this version, which is what makes the "after" run a real check.
#
# Output is written to .security-evidence/<group>-<label>.txt and echoed to stdout.
# Deliberately NOT under build/, which `gradlew clean` wipes mid-run.

set -euo pipefail

GROUP="${1:?usage: capture-dependency-evidence.sh <group> <label> [min-version]}"
LABEL="${2:?usage: capture-dependency-evidence.sh <group> <label> [min-version]}"
MIN_VERSION="${3:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR=".security-evidence"
OUT_FILE="${OUT_DIR}/${GROUP}-${LABEL}.txt"
mkdir -p "$OUT_DIR"

{
  echo "group:       ${GROUP}"
  echo "label:       ${LABEL}"
  echo "commit:      $(git rev-parse --short HEAD 2>/dev/null || echo 'n/a')"
  echo "captured at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo
} > "$OUT_FILE"

# `dependencies` prints every configuration; keep only lines naming the group, and normalise the
# Gradle arrows ("1.2.3 -> 4.5.6") down to the version that is actually resolved.
./gradlew --quiet --console=plain dependencies \
  | grep -E "[-+\\\\|[:space:]]+${GROUP}:" \
  | sed -E 's/^[^A-Za-z]*//; s/ \(\*\)$//; s/ \(n\)$//' \
  | sort -u \
  >> "$OUT_FILE" || true

RESOLVED_VERSIONS="$(
  grep -oE "${GROUP}:[A-Za-z0-9._-]+:[0-9][A-Za-z0-9._-]*( -> [0-9][A-Za-z0-9._-]*)?" "$OUT_FILE" \
    | sed -E 's/.* -> /RESOLVED /; s/^'"${GROUP}"':[A-Za-z0-9._-]+:/RESOLVED /' \
    | awk '{print $2}' \
    | sort -uV || true
)"

{
  echo
  echo "distinct resolved versions:"
  if [[ -z "$RESOLVED_VERSIONS" ]]; then
    echo "  (none - ${GROUP} does not appear in any configuration)"
  else
    echo "$RESOLVED_VERSIONS" | sed 's/^/  /'
  fi
} >> "$OUT_FILE"

cat "$OUT_FILE"

if [[ -n "$MIN_VERSION" && -n "$RESOLVED_VERSIONS" ]]; then
  stale=0
  while IFS= read -r version; do
    [[ -z "$version" ]] && continue
    # Oldest of {version, MIN_VERSION} under version sort; if it is not MIN_VERSION, version is older.
    oldest="$(printf '%s\n%s\n' "$version" "$MIN_VERSION" | sort -V | head -n1)"
    if [[ "$oldest" != "$MIN_VERSION" && "$version" != "$MIN_VERSION" ]]; then
      echo "FAIL: ${GROUP} resolves ${version}, which is older than required ${MIN_VERSION}" >&2
      stale=1
    fi
  done <<< "$RESOLVED_VERSIONS"

  if [[ "$stale" -ne 0 ]]; then
    exit 1
  fi
  echo "OK: every resolved ${GROUP} artifact is at or above ${MIN_VERSION}"
fi
