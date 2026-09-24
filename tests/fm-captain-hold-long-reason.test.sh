#!/usr/bin/env bash
# A second mate's captain hold must reach the parent channel with its whole
# question, or refuse loudly without holding; exit 0 with a cut or missing
# question on the only captain-facing record is the defect under test.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-captain-hold-long-reason)

make_mate() {  # <name>; prints the mate home, whose parent is <mate>/parent
  local mate="$TMP_ROOT/$1"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/parent/state"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$mate/data/backlog.md"
  printf 'long-mate\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$mate/parent" \
    > "$mate/.fm-secondmate-parent"
  printf '%s\n' "$mate"
}

run_captain() {  # <mate> <command args...>
  local mate=$1
  shift
  FM_HOME="$mate" FM_STATE_OVERRIDE="$mate/state" FM_DATA_OVERRIDE="$mate/data" \
    FM_CONFIG_OVERRIDE="$mate/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

question_of_length() {  # <bytes> <tail>
  local text='' unit='Option A keeps the lane open until upstream lands; option B parks it now. '
  while [ "${#text}" -lt "$1" ]; do text=$text$unit; done
  printf '%s%s' "${text:0:$1}" "$2"
}

latest_parent_question() {  # <mate> <task-id>
  local line='' candidate
  [ -f "$1/parent/state/long-mate.status" ] || return 0
  while IFS= read -r candidate; do
    case "$candidate" in "needs-decision [key=captain-hold-$2-1]"*) line=$candidate ;; esac
  done < "$1/parent/state/long-mate.status"
  printf '%s' "${line#*": captain hold $2: "}"
}

expect_whole_or_loud_refusal() {  # <mate> <task-id> <reason> <rc> <stderr> <label>
  local mate=$1 id=$2 reason=$3 rc=$4 err=$5 label=$6 open_rc=0 seen
  seen=$(latest_parent_question "$mate" "$id")
  if [ "$rc" -eq 0 ]; then
    [ "$seen" = "$reason" ] \
      || fail "$label: exit 0 but the parent channel carries ${#seen} of the question's ${#reason} bytes"
    return 0
  fi
  assert_contains "$err" reason "$label: refusal does not name the reason"
  case "$err" in *[0-9]*) : ;; *) fail "$label: refusal does not name the limit: $err" ;; esac
  run_captain "$mate" open "$id" >/dev/null 2>&1 || open_rc=$?
  [ "$open_rc" -ne 0 ] || fail "$label: refused with exit $rc yet left $id held for the captain"
  case "$reason" in
    "$seen"?*) [ -z "$seen" ] || fail "$label: refused yet a cut copy of the question reached the parent" ;;
  esac
}

test_long_question_reaches_parent_whole_or_refuses() {
  local mate case_spec bytes id reason rc err
  mate=$(make_mate single)
  for case_spec in modest-question:2000 huge-question:100000; do
    id=${case_spec%%:*}
    bytes=${case_spec#*:}
    reason=$(question_of_length "$bytes" ' Recommendation: option B.')
    rc=0
    err=$(run_captain "$mate" hold "$id" --title "Long captain question" \
      --reason "$reason" 2>&1 >/dev/null) || rc=$?
    expect_whole_or_loud_refusal "$mate" "$id" "$reason" "$rc" "$err" "$bytes-byte hold"
  done
  pass "a long captain question reaches the parent channel whole or the hold refuses"
}

test_revised_long_question_reaches_parent_or_refuses() {
  local mate first revised rc err
  mate=$(make_mate revised)
  first=$(question_of_length 2000 ' Recommendation: ship.')
  revised=$(question_of_length 2000 ' Recommendation: park.')
  run_captain "$mate" hold revised-question --title "Revised captain question" \
    --reason "$first" >/dev/null 2>&1 || :
  rc=0
  err=$(run_captain "$mate" hold revised-question --title "Revised captain question" \
    --reason "$revised" 2>&1 >/dev/null) || rc=$?
  expect_whole_or_loud_refusal "$mate" revised-question "$revised" "$rc" "$err" "revised hold"
  pass "a revised long captain question reaches the parent channel or the hold refuses"
}

test_long_question_reaches_parent_whole_or_refuses
test_revised_long_question_reaches_parent_or_refuses
