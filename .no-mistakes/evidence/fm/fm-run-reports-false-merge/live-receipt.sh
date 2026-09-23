#!/usr/bin/env bash
# Usage: live-receipt.sh <fm-root>: valid merge-poll retirement receipt for OPEN PR #87, real gh read.
set -u
ROOT=$1
. "$ROOT/bin/fm-pr-lib.sh"
T=$(mktemp -d /tmp/fm-rcpt-XXXXXX); mkdir -p "$T/state" "$T/fakebin" "$T/wt"
git -C "$T/wt" init -q; git -C "$T/wt" -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m i; git -C "$T/wt" checkout -q -b fm/feat-live
HEAD=$(git -C "$T/wt" rev-parse HEAD)
cat > "$T/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = axi ] && printf '%s\n' "$FM_FAKE_AXI_STATUS"
exit 0
SH
chmod +x "$T/fakebin/no-mistakes"
url=https://github.com/dbeihl-utilicast/firstmate/pull/87
printf "window=fm:fm-feat-live\nworktree=%s\nkind=ship\npr=%s\n" "$T/wt" "$url" > "$T/state/feat-live.meta"
fm_pr_url_parse "$url"
tpl="$ROOT/bin/fm-pr-poll.sh"
fm_pr_poll_prepare "$T/state" feat-live "$FM_PR_PROVIDER" "$url" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" "$tpl" && fm_pr_poll_publish_prepared \
 && fm_pr_poll_snapshot_capture "$T/state" feat-live "$tpl" && fm_pr_poll_retirement_publish "$T/state" feat-live "$tpl" merged || { echo "receipt seed failed"; exit 2; }
echo "receipt valid: $(fm_pr_poll_retirement_receipt_valid "$T/state" feat-live && echo yes || echo no)"
st=$(printf 'run:\n  id: "01RUN"\n  branch: fm/feat-live\n  status: completed\n  head: "%s"\n  pr: "%s"\n  findings: none\noutcome: passed\n' "$HEAD" "$url")
for nf in 0 1; do
  printf 'receipt + OPEN PR #87, NO_FORGE=%s => ' $nf
  FM_CREW_STATE_NO_FORGE=$nf FM_FAKE_AXI_STATUS="$st" PATH="$T/fakebin:$PATH" FM_STATE_OVERRIDE="$T/state" "$ROOT/bin/fm-crew-state.sh" feat-live 2>&1 | tr '\n' ' '; echo
done
rm -rf "$T"
