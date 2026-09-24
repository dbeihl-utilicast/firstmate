#!/usr/bin/env bash
# Live CLI drive of bin/fm-captain-hold.sh hold against throwaway homes.
set -u
ROOT=$1
T=$(mktemp -d)
mk() {
  local m="$T/$1"
  mkdir -p "$m/data" "$m/state" "$m/config" "$m/parent/state"
  cp "$ROOT/.tasks.toml" "$m/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$m/data/backlog.md"
  if [ "${2:-}" = mate ]; then
    printf 'long-mate\n' > "$m/.fm-secondmate-home"
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$m/parent" > "$m/.fm-secondmate-parent"
  fi
  printf '%s' "$m"
}
cap() { local m=$1; shift; FM_HOME="$m" FM_STATE_OVERRIDE="$m/state" FM_DATA_OVERRIDE="$m/data" FM_CONFIG_OVERRIDE="$m/config" "$ROOT/bin/fm-captain-hold.sh" "$@"; }
rep() { local n=$1 s=$2 o=''; while [ "${#o}" -lt "$n" ]; do o=$o$s; done; printf '%s' "${o:0:$n}"; }
show() {  # <mate> <id> <reason>
  local m=$1 id=$2 reason=$3 rc=0 line q
  echo "### hold $id (reason $(printf '%s' "$reason" | LC_ALL=C wc -c) bytes)"
  cap "$m" hold "$id" --title "Q $id" --reason "$reason" >/dev/null 2>"$T/err" || rc=$?
  echo "exit=$rc"; [ -s "$T/err" ] && sed 's/^/stderr: /' "$T/err"
  line=$(grep -F "key=captain-hold-$id-1" "$m/parent/state/long-mate.status" 2>/dev/null | tail -1)
  q=${line#*": captain hold $id: "}
  if [ -z "$line" ]; then echo "parent channel: no line for $id"
  elif [ "$q" = "$reason" ]; then echo "parent channel: whole question ($(printf '%s' "$q" | LC_ALL=C wc -c) bytes)"
  else echo "parent channel: DIFFERS ($(printf '%s' "$q" | LC_ALL=C wc -c) bytes)"; fi
  cap "$m" open "$id" >/dev/null 2>&1 && echo "backlog: $id is held" || echo "backlog: $id not held"
  echo
}
M=$(mk mate mate)
show "$M" at-limit "$(rep 1200 'Option A or B? ')"
show "$M" over-by-one "$(rep 1201 'Option A or B? ')"
show "$M" huge "$(rep 100000 'Option A or B? ')"
show "$M" multibyte "$(rep 700 'é')"
show "$M" short 'Ship A or B?'
echo "### revise short hold with a long reason"
show "$M" short "$(rep 2000 'Revised: A or B? ')"
echo "### main home (no parent channel), long reason"
H=$(mk main)
rc=0; cap "$H" hold main-long --title "Main" --reason "$(rep 2000 'Main A or B? ')" >/dev/null 2>"$T/err" || rc=$?
echo "exit=$rc"; cat "$T/err"; cap "$H" open main-long >/dev/null 2>&1 && echo "backlog: held" || echo "backlog: not held"
rm -rf "$T"
