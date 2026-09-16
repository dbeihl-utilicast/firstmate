#!/usr/bin/env bash
# Drives the VERBATIM classify step extracted from .github/workflows/ci.yml
# against a real clone of the repository with a real commit on top.
set -uo pipefail
SRC=$1; shift
WORK=/tmp/nm-drive/repo
rm -rf "$WORK"
git clone -q --no-hardlinks "$SRC" "$WORK" 2>/dev/null
cd "$WORK"

run_case() {
  local label=$1; shift
  git checkout -q -B probe "$BASE_REF" 2>/dev/null
  "$@"
  git add -A >/dev/null
  git -c user.email=t@t -c user.name=t commit -q -m "probe: $label"
  local out; out=$(mktemp)
  local log; log=$(mktemp)
  local rc=0
  BASE_SHA="$BASE_REF" GITHUB_OUTPUT="$out" bash /tmp/nm-drive/classify-step.sh >"$log" 2>&1 || rc=$?
  local verdict; verdict=$(grep -o 'docs_only=.*' "$out" 2>/dev/null || echo 'docs_only=<none>')
  printf '%-58s | changed=%-44s | %s | step_rc=%s\n' \
    "$label" "$(git diff --name-only "$BASE_REF"...HEAD | tr '\n' ',' | sed 's/,$//' | cut -c1-44)" "$verdict" "$rc"
}

BASE_REF=$(git rev-parse HEAD)
echo "base commit: $BASE_REF"
echo
printf '%-58s | %-53s | %s\n' 'SCENARIO' 'CHANGED PATHS' 'CLASSIFIER VERDICT'
printf '%s\n' "$(printf '=%.0s' {1..150})"

run_case "prose-only: README.md typo"                bash -c 'printf "\n<!-- probe -->\n" >> README.md'
run_case "prose-only: VISION.md (unmapped doc)"      bash -c 'printf "\n<!-- probe -->\n" >> VISION.md'
run_case "runtime prose: docs/supervision-protocols/codex.md" bash -c 'printf "\n<!-- probe -->\n" >> docs/supervision-protocols/codex.md'
run_case "runtime prose: .agents/skills harness-adapters SKILL.md" bash -c 'printf "\n<!-- probe -->\n" >> .agents/skills/harness-adapters/SKILL.md'
run_case "runtime prose: AGENTS.md"                  bash -c 'printf "\n<!-- probe -->\n" >> AGENTS.md'
run_case "non-md docs fixture: docs/examples/*.json" bash -c 'f=$(ls docs/examples/*.json | head -1); printf "\n" >> "$f"'
run_case "code: bin/fm-lint.sh"                      bash -c 'printf "\n" >> bin/fm-lint.sh'
run_case "code: .github/workflows/ci.yml"            bash -c 'printf "\n" >> .github/workflows/ci.yml'
run_case "mixed: README.md + bin/fm-lint.sh"         bash -c 'printf "\n" >> README.md; printf "\n" >> bin/fm-lint.sh'
