#!/usr/bin/env bash
# Drives the real bin/fm-lint.sh (the pinned commands.lint owner) on a real
# clone, on exactly the branch shape the docs-only CI skip creates.
set -uo pipefail
W=/tmp/nm-drive/lintrepo
rm -rf "$W"
git clone -q --no-hardlinks "$1" "$W" 2>/dev/null
cd "$W"
git checkout -q -B main 2>/dev/null
git checkout -q -B docs-only-branch

show() { printf '\n----- %s -----\n' "$1"; }

# A documentation-only branch: one prose commit, zero changed shell files.
printf '\n<!-- probe -->\n' >> README.md
git add -A >/dev/null; git -c user.email=t@t -c user.name=t commit -q -m 'docs: prose tweak'

show "1. docs-only branch, CI unset (the LOCAL pre-push path) - clean docs"
rc=0; out=$(env -u CI FM_LINT_BASE_REF=main timeout 600 bin/fm-lint.sh 2>&1) || rc=$?
printf '%s\n' "$out" | grep -E 'changed lint targets|workflow files valid|fm-doc-audience-check' || printf '%s\n' "$out" | tail -8
echo "exit=$rc"

show "2. same branch, but the prose commit BREAKS a local link (regression)"
printf '\n[nope](docs/this-page-does-not-exist.md)\n' >> README.md
git add -A >/dev/null; git -c user.email=t@t -c user.name=t commit -q -m 'docs: break a link'
rc=0; out=$(env -u CI FM_LINT_BASE_REF=main timeout 600 bin/fm-lint.sh 2>&1) || rc=$?
printf '%s\n' "$out" | grep -E 'changed lint targets|workflow files valid|fm-doc-audience|unresolved|audience' || printf '%s\n' "$out" | tail -8
echo "exit=$rc"

show "3. same branch, prose commit adds an UNCLASSIFIED doc surface"
git checkout -q README.md 2>/dev/null; git -c user.email=t@t -c user.name=t checkout -q HEAD~1 -- README.md
printf '# Brand new surface\n' > docs/probe-new-surface.md
git add -A >/dev/null; git -c user.email=t@t -c user.name=t commit -q -m 'docs: add an unclassified surface'
rc=0; out=$(env -u CI FM_LINT_BASE_REF=main timeout 600 bin/fm-lint.sh 2>&1) || rc=$?
printf '%s\n' "$out" | grep -E 'changed lint targets|workflow files valid|fm-doc-audience|unclassified|audience|inventory' || printf '%s\n' "$out" | tail -8
echo "exit=$rc"
