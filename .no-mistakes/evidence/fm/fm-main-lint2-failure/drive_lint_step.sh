#!/usr/bin/env bash
# Python stand-in for the test's ruby extraction (ruby absent on host); same stub + same step execution.
set -u
WF=${1:?workflow}
tmp=$(mktemp -d); mkdir -p "$tmp/bin" "$tmp/runner"
cat > "$tmp/bin/fm-lint.sh" <<'SH'
#!/usr/bin/env bash
jobs=${FM_LINT_JOBS:-2}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jobs) jobs=$2; shift 2 ;;
    --jobs=*) jobs=${1#*=}; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$jobs" > "$FM_STUB_JOBS_LOG"
SH
chmod +x "$tmp/bin/fm-lint.sh"
script=$(python3 - "$WF" <<'PY'
import sys,yaml
steps=yaml.safe_load(open(sys.argv[1]))["jobs"]["lint"]["steps"]
run=[s for s in steps if s.get("name")=="Lint canonical partition"][0]["run"]
run=run.replace("${{ matrix.partition }}","2").replace("${{ strategy.job-total }}","2")
assert "${{" not in run
print(run)
PY
)
(cd "$tmp" && env -u FM_LINT_JOBS RUNNER_TEMP="$tmp/runner" FM_STUB_JOBS_LOG="$tmp/jobs.log" bash -c "$script") || echo "step failed"
echo "effective jobs=$(cat $tmp/jobs.log)"
rm -rf "$tmp"
