#!/usr/bin/env bash
# Usage: live-drive.sh <fm-root> ; drives <fm-root>/bin/fm-crew-state.sh with REAL gh reads
# against dbeihl-utilicast/firstmate PRs, and a fake `no-mistakes` reporting a finished (passed) run.
set -u
ROOT=$1
T=$(mktemp -d /tmp/fm-live-XXXXXX)
mkdir -p "$T/state" "$T/fakebin" "$T/wt"
git -C "$T/wt" init -q; git -C "$T/wt" -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m init
git -C "$T/wt" checkout -q -b fm/feat-live
HEAD=$(git -C "$T/wt" rev-parse HEAD)
cat > "$T/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = axi ] && { shift; if [ "${1:-}" = status ] || [ $# = 0 ]; then printf '%s\n' "$FM_FAKE_AXI_STATUS"; fi; }
exit 0
SH
chmod +x "$T/fakebin/no-mistakes"
drive() {  # <label> <pr-url> [env...]
  local label=$1 url=$2; shift 2
  printf 'window=fm:fm-feat-live\nworktree=%s\nkind=ship\n' "$T/wt" > "$T/state/feat-live.meta"
  local st; st=$(printf 'run:\n  id: "01RUN"\n  branch: fm/feat-live\n  status: completed\n  head: "%s"\n  pr: "%s"\n  findings: none\noutcome: passed\n' "$HEAD" "$url")
  printf '%-58s => ' "$label"
  env "$@" FM_FAKE_AXI_STATUS="$st" PATH="$T/fakebin:$PATH" FM_STATE_OVERRIDE="$T/state" "$ROOT/bin/fm-crew-state.sh" feat-live 2>&1 | tr '\n' ' '
  echo
}
R=https://github.com/dbeihl-utilicast/firstmate/pull
drive "OPEN PR #87 (real forge)"                       $R/87 X=1
drive "MERGED PR #86 w/ merge commit (real forge)"     $R/86 X=1
drive "CLOSED-unmerged PR #75 (real forge)"            $R/75 X=1
drive "MERGED PR #86, FM_CREW_STATE_NO_FORGE=1"        $R/86 FM_CREW_STATE_NO_FORGE=1
drive "nonexistent PR #999999 (unreadable forge)"      $R/999999 X=1
drive "no PR identity"                                 "" X=1
rm -rf "$T"
