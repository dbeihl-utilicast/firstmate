set -eu
# Prose extension alone is not evidence of inertness: docs/ also holds
# test fixtures, and several tracked *.md files are runtime input. The
# repository's own change-to-test map decides, and anything it cannot
# classify falls through as not documentation-only.
docs_only=false
changed=$(git diff --name-only "${BASE_SHA}...HEAD")
printf '%s\n' "$changed"
if [ -n "$changed" ] && ! printf '%s\n' "$changed" | grep -qvE '\.md$'; then
  if selected=$(bin/fm-test-run.sh --list --changed --base "$BASE_SHA"); then
    [ -n "$selected" ] || docs_only=true
  fi
fi
echo "docs_only=$docs_only" >> "$GITHUB_OUTPUT"
