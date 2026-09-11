#!/usr/bin/env bash
set -eu
cd /Users/davidsair/.no-mistakes/worktrees/2f2b4426b91c/01M295FW69QR2TJ5G0SBE0ZPMF
export PHASE_EVIDENCE=/Users/davidsair/.no-mistakes/evidence/01M295FW69QR2TJ5G0SBE0ZPMF
probe=$(mktemp -d "$PWD/.test-phase-probe.XXXXXX")
trap 'rm -rf "$probe"' EXIT
export PHASE_PROBE="$probe"
git show 8875e45:bin/fm-pr-poll.sh > "$probe/subtract.sh"
node <<'JS'
const fs = require('node:fs');
const source = fs.readFileSync('bin/fm-pr-poll.sh','utf8');
const anchor = '      [ -n "$base_ref" ] || exit 0\n';
if (source.split(anchor).length !== 2) throw Error('Mutation anchor must occur once');
fs.writeFileSync(process.env.PHASE_PROBE+'/add.sh', source.replace(anchor,anchor+'      exit 0\n'));
fs.writeFileSync(process.env.PHASE_PROBE+'/substitute.sh',source.replace(anchor,anchor+'      base_ref=$base_name\n'));
JS
poll_control() {
  local dir observed
  POLL=$PHASE_POLL
  dir=$(make_case control-observation)
  make_poll_fixture "$dir"
  observed=$(FM_TEST_GH_STATE=OPEN FM_TEST_GH_MERGE_STATE=BLOCKED FM_TEST_GH_BEHIND_BY=2 \
    FM_TEST_GH_BASE_NAME='release/v1+hotfix' run_poll "$dir")
  {
    printf '\nVariant: %s\nPublic poll stdout: <%s>\nGitHub CLI arguments:\n' "$PHASE_VARIANT" "$observed"
    cat "$dir/gh.log"
  } >> "$PHASE_EVIDENCE/base-ref-before-after.txt"
  test_static_poll_base_ref_encoding
}
export -f poll_control
printf 'Executable poll with base release/v1+hotfix. Identical behavioral test executed against prior source, two deliberate mutations, and target.\n' > "$PHASE_EVIDENCE/base-ref-before-after.txt"
for variant in subtract add substitute target; do
  poll="$probe/$variant.sh"
  [ "$variant" != target ] || poll="$PWD/bin/fm-pr-poll.sh"
  rc=0
  PHASE_VARIANT="$variant" PHASE_POLL="$poll" FM_TEST_ONLY=poll_control \
    bin/fm-test-run.sh tests/fm-pr-check-security.test.sh > "$PHASE_EVIDENCE/poll-control-$variant.log" 2>&1 || rc=$?
  {
    printf 'Behavioral regression exit=%s\n' "$rc"
    cat "$PHASE_EVIDENCE/poll-control-$variant.log"
  } >> "$PHASE_EVIDENCE/base-ref-before-after.txt"
  if [ "$variant" = target ]; then
    [ "$rc" -eq 0 ] || exit 1
  else
    [ "$rc" -eq 1 ] || exit 1
    grep -qF 'not ok - static poll skipped valid base release/v1+hotfix' "$PHASE_EVIDENCE/poll-control-$variant.log" || exit 1
  fi
  printf '%s: expected exit %s observed\n' "$variant" "$rc"
done
