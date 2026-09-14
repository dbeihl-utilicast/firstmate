#!/usr/bin/env bash
# Portable regression for the remote doctor's optional Claude Code plugin catalogue.
#
# Drives bin/fm-remote-doctor.sh through its public check/--fix interface with a
# stub claude on PATH. Other host gaps still print; this file asserts only the
# host-plugins check, its repair commands, and that removing either goes red.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (catalogue JSON parsing)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-doctor-host-plugins)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

TOOLS="$TMP_ROOT/tools"
mkdir -p "$TOOLS"
ln -sf "$(command -v git)" "$TOOLS/git"
[ -n "$(command -v jq 2>/dev/null)" ] && ln -sf "$(command -v jq)" "$TOOLS/jq"
ln -sf "$(command -v python3)" "$TOOLS/python3"
BASE_PATH="$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin"

# shellcheck source=bin/fm-config-inherit-lib.sh
. "$ROOT/bin/fm-config-inherit-lib.sh"
case "$(fm_config_inherit_items)" in
  *config/host-plugins.json*) ;;
  *) fail "config/host-plugins.json must be inherited so a remote home can see the catalogue" ;;
esac
pass "the plugin catalogue is on the inherited local-material allowlist"

write_catalogue() { # <fm-home>
  mkdir -p "$1/config"
  cat > "$1/config/host-plugins.json" <<'JSON'
{
  "marketplaces": [
    {
      "name": "example-plugins",
      "source": "https://github.com/example/example-plugins.git"
    }
  ],
  "plugins": [
    "example-core@example-plugins"
  ]
}
JSON
}

write_stub_claude() { # <state-dir>
  local state=$1 real_git
  real_git=$(command -v git)
  mkdir -p "$state/bin" "$state/details" "$state/marketplace/.claude-plugin" \
    "$state/marketplace/plugins/example-core/.claude-plugin"
  : > "$state/commands.log"
  printf '[]\n' > "$state/marketplaces.json"
  printf '[]\n' > "$state/plugins.json"
  printf 'ok\n' > "$state/add.mode"
  printf 'ok\n' > "$state/install.mode"
  cat > "$state/details/example-core@example-plugins" <<'TXT'
example-core 1.0.0
  Source: example-core@example-plugins

Component inventory
  Skills (2)  example-skill, other-skill
TXT
  cat > "$state/marketplace/.claude-plugin/marketplace.json" <<'JSON'
{
  "name": "example-plugins",
  "plugins": [
    {
      "name": "example-core",
      "source": "./plugins/example-core"
    }
  ]
}
JSON
  cat > "$state/marketplace/plugins/example-core/.claude-plugin/plugin.json" <<'JSON'
{
  "name": "example-core",
  "version": "1.0.0",
  "dependencies": []
}
JSON
  cat > "$state/bin/git" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = clone ]; then
  destination=\${!#}
  mkdir -p "\$destination"
  cp -R "$state/marketplace/." "\$destination/"
  exit 0
fi
exec "$real_git" "\$@"
SH
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -u' "state='$state'"
    cat <<'SH'
printf '%s\n' "claude_config=${CLAUDE_CONFIG_DIR:-} $*" >> "$state/commands.log"
json_flag=0
scope=user
yes=0
args=()
for arg in "$@"; do
  case "$arg" in
    --json) json_flag=1 ;;
    --scope) ;;
    user|project|local) scope=$arg ;;
    --yes|-y) yes=1 ;;
    --) ;;
    *) args+=("$arg") ;;
  esac
done
set -- "${args[@]}"
case "${1:-} ${2:-} ${3:-}" in
  "plugin marketplace list"*)
    [ "$json_flag" -eq 1 ] || exit 1
    cat "$state/marketplaces.json"
    exit 0
    ;;
  "plugin marketplace add"*)
    source=${4:-${3:-}}
    case "$(cat "$state/add.mode")" in
      auth)
        printf 'fatal: Authentication failed for %s\n' "$source" >&2
        exit 1
        ;;
      fail)
        printf 'error: marketplace add refused\n' >&2
        exit 1
        ;;
    esac
    python3 - "$state/marketplaces.json" "$source" "$state/marketplace" <<'PY'
import json, os, sys
path, source, install_location = sys.argv[1], sys.argv[2], sys.argv[3]
name = "example-plugins"
if "other" in source:
    name = "other-plugins"
data = []
if os.path.exists(path):
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
if not any(item.get("name") == name for item in data):
    data.append({"name": name, "source": "git", "url": source, "installLocation": install_location})
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PY
    exit 0
    ;;
  "plugin list"*)
    [ "$json_flag" -eq 1 ] || exit 1
    cat "$state/plugins.json"
    exit 0
    ;;
  "plugin install"*)
    plugin=${4:-${3:-}}
    case "$(cat "$state/install.mode")" in
      auth)
        printf 'fatal: Authentication failed while installing %s\n' "$plugin" >&2
        exit 1
        ;;
      fail)
        printf 'error: plugin install refused\n' >&2
        exit 1
        ;;
    esac
    python3 - "$state/plugins.json" "$plugin" "$state/marketplace/plugins/example-core" <<'PY'
import json, os, sys
path, plugin, install_path = sys.argv[1], sys.argv[2], sys.argv[3]
data = []
if os.path.exists(path):
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
if not any(item.get("id") == plugin for item in data):
    data.append({"id": plugin, "scope": "user", "enabled": True, "installPath": install_path})
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PY
    exit 0
    ;;
  "plugin enable"*)
    plugin=${4:-${3:-}}
    python3 - "$state/plugins.json" "$plugin" <<'PY'
import json, os, sys
path, plugin = sys.argv[1], sys.argv[2]
data = []
if os.path.exists(path):
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
for item in data:
    if item.get("id") == plugin:
        item["enabled"] = True
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PY
    exit 0
    ;;
  "plugin details"*)
    plugin=${3:-}
    if [ -f "$state/details/$plugin" ]; then
      cat "$state/details/$plugin"
      exit 0
    fi
    printf 'error: plugin not found\n' >&2
    exit 1
    ;;
esac
printf 'unexpected claude invocation: %s\n' "$*" >&2
exit 64
SH
  } > "$state/bin/claude"
  chmod +x "$state/bin/claude" "$state/bin/git"
}

run_doctor() { # [--fix]
  set +e
  DOCTOR_OUT=$(
    HOME="$CASE_HOME" \
    FM_HOME="$CASE_FM_HOME" \
    CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-}" \
    PATH="$CASE_CLAUDE_BIN:$BASE_PATH" \
    "$ROOT/bin/fm-remote-doctor.sh" "$@" 2>&1
  )
  set -e
}

new_host() {
  CASE_N=${CASE_N:-0}
  CASE_N=$((CASE_N + 1))
  CASE_DIR="$TMP_ROOT/case$CASE_N"
  CASE_HOME="$CASE_DIR/home"
  CASE_FM_HOME="$CASE_DIR/fm-home"
  CASE_STATE="$CASE_DIR/claude-state"
  mkdir -p "$CASE_HOME" "$CASE_FM_HOME"
  write_stub_claude "$CASE_STATE"
  CASE_CLAUDE_BIN="$CASE_STATE/bin"
}

# --- absent config: skip, never talk to claude, --fix is a no-op ------------

new_host
run_doctor
assert_contains "$DOCTOR_OUT" 'check host-plugins=skip: no host plugin catalogue is configured' \
  "absent config did not skip the plugin check"
[ ! -s "$CASE_STATE/commands.log" ] || fail "absent config invoked claude"
: > "$CASE_STATE/commands.log"
run_doctor --fix
assert_contains "$DOCTOR_OUT" 'check host-plugins=skip: no host plugin catalogue is configured' \
  "--fix with absent config did not keep skipping"
assert_not_contains "$DOCTOR_OUT" 'fix host-plugins=' "--fix with absent config printed a plugin repair"
[ ! -s "$CASE_STATE/commands.log" ] || fail "--fix with absent config invoked claude"
pass "absent config is not applicable and changes nothing"

# --- claude missing is a named operator gap, and Claude Code is not installed

new_host
write_catalogue "$CASE_FM_HOME"
CASE_CLAUDE_BIN="$CASE_DIR/empty-bin"
mkdir -p "$CASE_CLAUDE_BIN"
run_doctor
assert_contains "$DOCTOR_OUT" 'check host-plugins=human:' "missing claude CLI was not a human gap"
assert_contains "$DOCTOR_OUT" 'install Claude Code' "missing claude CLI did not name the operator action"
assert_not_contains "$DOCTOR_OUT" 'fix host-plugins=applied' "the doctor claimed to install Claude Code"
pass "a missing claude CLI is reported and Claude Code is not installed"

# --- missing marketplace: --fix adds only the configured source -------------

new_host
write_catalogue "$CASE_FM_HOME"
run_doctor
assert_contains "$DOCTOR_OUT" 'check host-plugins=fixable: configured marketplace is not registered' \
  "a missing marketplace was not fixable"
assert_contains "$DOCTOR_OUT" 'example-plugins' "the missing marketplace was not named"
: > "$CASE_STATE/commands.log"
run_doctor --fix
assert_contains "$DOCTOR_OUT" 'fix host-plugins=applied: registered marketplace example-plugins' \
  "--fix did not register the configured marketplace"
assert_contains "$DOCTOR_OUT" 'fix host-plugins=applied: installed example-core@example-plugins' \
  "--fix did not install the configured plugin after registering its marketplace"
assert_contains "$DOCTOR_OUT" 'check host-plugins=ok: configured Claude Code plugins resolve on this host' \
  "--fix did not prove a skill resolves after install"
assert_contains "$(cat "$CASE_STATE/commands.log")" 'plugin marketplace add -- https://github.com/example/example-plugins.git' \
  "--fix did not add the configured marketplace source"
assert_contains "$(cat "$CASE_STATE/commands.log")" 'plugin install --scope user --yes -- example-core@example-plugins' \
  "--fix did not install the configured plugin id"
assert_not_contains "$(cat "$CASE_STATE/commands.log")" 'other-plugins' \
  "--fix added a marketplace that is not in config"
pass "a missing marketplace is registered and its plugin is installed, then a skill resolves"

# --- missing plugin only ----------------------------------------------------

new_host
write_catalogue "$CASE_FM_HOME"
python3 - "$CASE_STATE/marketplaces.json" "$CASE_STATE/marketplace" <<'PY'
import json, sys
json.dump([{"name": "example-plugins", "source": "git", "url": "https://github.com/example/example-plugins.git", "installLocation": sys.argv[2]}], open(sys.argv[1], "w"))
PY
run_doctor
assert_contains "$DOCTOR_OUT" 'check host-plugins=fixable: configured plugin is not installed (example-core@example-plugins)' \
  "a missing plugin was not fixable"
: > "$CASE_STATE/commands.log"
run_doctor --fix
assert_contains "$DOCTOR_OUT" 'fix host-plugins=applied: installed example-core@example-plugins' \
  "--fix did not install the missing plugin"
assert_contains "$DOCTOR_OUT" 'check host-plugins=ok:' "--fix did not re-check plugin resolution"
assert_not_contains "$(cat "$CASE_STATE/commands.log")" 'plugin marketplace add' \
  "--fix re-added a marketplace that was already registered"
pass "a missing plugin is installed without touching an already-registered marketplace"

# --- auth failure leaves the gap open and does not invent credentials -------

new_host
write_catalogue "$CASE_FM_HOME"
printf 'auth\n' > "$CASE_STATE/add.mode"
run_doctor --fix
assert_contains "$DOCTOR_OUT" 'fix host-plugins=failed:' "--fix did not report the authentication failure"
assert_contains "$DOCTOR_OUT" 'authentication' "--fix did not name authentication as the operator action"
assert_contains "$DOCTOR_OUT" 'check host-plugins=human:' "an auth failure was left as a silent or fixable loop"
assert_not_contains "$DOCTOR_OUT" 'fix host-plugins=applied' "--fix claimed success after authentication failed"
assert_contains "$(cat "$CASE_STATE/commands.log")" 'plugin marketplace add -- https://github.com/example/example-plugins.git' \
  "auth failure did not attempt the configured marketplace add"
assert_not_contains "$(cat "$CASE_STATE/commands.log")" 'plugin install' \
  "auth failure still installed a plugin"
pass "authentication failure reports the operator action and leaves the gap open"

# --- installed but no resolving skill is the same as absent -----------------

new_host
write_catalogue "$CASE_FM_HOME"
python3 - "$CASE_STATE/marketplaces.json" "$CASE_STATE/plugins.json" "$CASE_STATE/marketplace" <<'PY'
import json, sys
json.dump([{"name": "example-plugins", "source": "git", "url": "https://github.com/example/example-plugins.git", "installLocation": sys.argv[3]}], open(sys.argv[1], "w"))
json.dump([{"id": "example-core@example-plugins", "scope": "user", "enabled": True, "installPath": sys.argv[3] + "/plugins/example-core"}], open(sys.argv[2], "w"))
PY
printf 'example-core 1.0.0\n  Skills (0)\n' > "$CASE_STATE/details/example-core@example-plugins"
run_doctor
assert_contains "$DOCTOR_OUT" 'check host-plugins=human:' "a plugin with no resolving skill was not a gap"
assert_contains "$DOCTOR_OUT" 'no skill resolves' "install-without-skills was treated as success"
: > "$CASE_STATE/commands.log"
run_doctor --fix
assert_not_contains "$DOCTOR_OUT" 'fix host-plugins=applied' "--fix tried to repair an unresolving installed plugin"
pass "a plugin present but not resolving is the same as absent"

# --- converged host: --fix changes nothing and prints no new repair ---------

new_host
write_catalogue "$CASE_FM_HOME"
python3 - "$CASE_STATE/marketplaces.json" "$CASE_STATE/plugins.json" "$CASE_STATE/marketplace" <<'PY'
import json, sys
json.dump([{"name": "example-plugins", "source": "git", "url": "https://github.com/example/example-plugins.git", "installLocation": sys.argv[3]}], open(sys.argv[1], "w"))
json.dump([{"id": "example-core@example-plugins", "scope": "user", "enabled": True, "installPath": sys.argv[3] + "/plugins/example-core"}], open(sys.argv[2], "w"))
PY
run_doctor
assert_contains "$DOCTOR_OUT" 'check host-plugins=ok: configured Claude Code plugins resolve on this host' \
  "a converged catalogue was not ok"
: > "$CASE_STATE/commands.log"
run_doctor --fix
assert_contains "$DOCTOR_OUT" 'check host-plugins=ok: configured Claude Code plugins resolve on this host' \
  "--fix on a converged host lost the ok verdict"
assert_not_contains "$DOCTOR_OUT" 'fix host-plugins=' "--fix on a converged host printed a plugin repair"
assert_not_contains "$(cat "$CASE_STATE/commands.log")" 'plugin marketplace add' \
  "--fix on a converged host added a marketplace"
assert_not_contains "$(cat "$CASE_STATE/commands.log")" 'plugin install' \
  "--fix on a converged host installed a plugin"
assert_not_contains "$(cat "$CASE_STATE/commands.log")" 'plugin enable' \
  "--fix on a converged host enabled a plugin"
pass "a converged host changes nothing and prints no plugin repair"

# --- same name from a different source is not the configured marketplace ----

new_host
write_catalogue "$CASE_FM_HOME"
python3 - "$CASE_STATE/marketplaces.json" "$CASE_STATE/plugins.json" "$CASE_STATE/marketplace" <<'PY'
import json, sys
json.dump([{"name": "example-plugins", "source": "git", "url": "https://github.com/other/other-plugins.git", "installLocation": sys.argv[3]}], open(sys.argv[1], "w"))
json.dump([{"id": "example-core@example-plugins", "scope": "user", "enabled": True, "installPath": sys.argv[3] + "/plugins/example-core"}], open(sys.argv[2], "w"))
PY
: > "$CASE_STATE/commands.log"
run_doctor
assert_contains "$DOCTOR_OUT" 'check host-plugins=human: configured marketplace is registered from a different source' \
  "a same-name marketplace from another source was accepted"
assert_not_contains "$DOCTOR_OUT" 'check host-plugins=ok:' "a substituted marketplace source was treated as ready"
: > "$CASE_STATE/commands.log"
run_doctor --fix
assert_not_contains "$(cat "$CASE_STATE/commands.log")" 'plugin install' \
  "--fix installed a plugin from a marketplace bound to the wrong source"
assert_not_contains "$DOCTOR_OUT" 'fix host-plugins=applied: installed' \
  "--fix claimed to install from a mismatched marketplace"
pass "a marketplace is bound to its configured source"

# --- --skip-check host-plugins is the pre-inheritance pass ------------------

new_host
write_catalogue "$CASE_FM_HOME"
: > "$CASE_STATE/commands.log"
run_doctor --skip-check host-plugins
assert_contains "$DOCTOR_OUT" 'check host-plugins=skip: plugin catalogue is checked after inherited config lands' \
  "--skip-check host-plugins did not skip the catalogue"
[ ! -s "$CASE_STATE/commands.log" ] || fail "--skip-check host-plugins still invoked claude"
pass "the pre-inheritance doctor pass does not touch plugins"

# --- CLAUDE_CONFIG_DIR is the store the doctor talks to ---------------------

new_host
write_catalogue "$CASE_FM_HOME"
python3 - "$CASE_STATE/marketplaces.json" "$CASE_STATE/plugins.json" "$CASE_STATE/marketplace" <<'PY'
import json, sys
json.dump([{"name": "example-plugins", "source": "git", "url": "https://github.com/example/example-plugins.git", "installLocation": sys.argv[3]}], open(sys.argv[1], "w"))
json.dump([{"id": "example-core@example-plugins", "scope": "user", "enabled": True, "installPath": sys.argv[3] + "/plugins/example-core"}], open(sys.argv[2], "w"))
PY
: > "$CASE_STATE/commands.log"
CLAUDE_CONFIG_DIR="$CASE_DIR/claude-store" run_doctor
assert_contains "$(cat "$CASE_STATE/commands.log")" "claude_config=$CASE_DIR/claude-store" \
  "the doctor did not run claude against CLAUDE_CONFIG_DIR"
assert_contains "$DOCTOR_OUT" 'check host-plugins=ok:' "an isolated CLAUDE_CONFIG_DIR store was not accepted"
pass "the doctor uses CLAUDE_CONFIG_DIR as the effective Claude store"

new_host
write_catalogue "$CASE_FM_HOME"
python3 - "$CASE_FM_HOME/config/host-plugins.json" "$CASE_STATE/marketplace/.claude-plugin/marketplace.json" \
  "$CASE_STATE/marketplace/plugins/example-core/.claude-plugin/plugin.json" \
  "$CASE_STATE/marketplace/plugins/example-domain/.claude-plugin/plugin.json" <<'PY'
import json, pathlib, sys
domain_manifest = pathlib.Path(sys.argv[4])
domain_manifest.parent.mkdir(parents=True)
json.dump({
    "marketplaces": [{"name": "example-plugins", "source": "https://github.com/example/example-plugins.git"}],
    "plugins": ["example-core@example-plugins", "example-domain@example-plugins"],
}, open(sys.argv[1], "w"))
json.dump({
    "name": "example-plugins",
    "plugins": [
        {"name": "example-core", "source": "./plugins/example-core"},
        {"name": "example-domain", "source": "./plugins/example-domain"},
    ],
}, open(sys.argv[2], "w"))
json.dump({"name": "example-core", "version": "1.0.0", "dependencies": ["example-domain"]}, open(sys.argv[3], "w"))
json.dump({"name": "example-domain", "version": "1.0.0", "dependencies": ["example-ops"]}, open(domain_manifest, "w"))
PY
run_doctor --fix
assert_contains "$DOCTOR_OUT" 'check host-plugins=human: configured plugin dependency is not named' \
  "an uncatalogued dependency was not a named host-plugin gap"
assert_contains "$DOCTOR_OUT" 'example-domain@example-plugins requires example-ops@example-plugins' \
  "the transitive dependency gap did not name both plugins"
[ "$(cat "$CASE_STATE/marketplaces.json")" = '[]' ] \
  || fail "dependency preflight mutated the effective marketplace store"
[ "$(cat "$CASE_STATE/plugins.json")" = '[]' ] \
  || fail "dependency preflight installed a plugin"
assert_not_contains "$(cat "$CASE_STATE/commands.log")" 'plugin install' \
  "an uncatalogued dependency still reached plugin install"
pass "uncatalogued dependencies refuse every effective-store mutation"

new_host
write_catalogue "$CASE_FM_HOME"
python3 - "$CASE_STATE/marketplaces.json" "$CASE_STATE/plugins.json" \
  "$CASE_STATE/marketplace" "$CASE_STATE/marketplace/plugins/example-core/.claude-plugin/plugin.json" <<'PY'
import json, sys
json.dump([{"name": "example-plugins", "source": "git", "url": "https://github.com/example/example-plugins.git", "installLocation": sys.argv[3]}], open(sys.argv[1], "w"))
json.dump([{"id": "example-core@example-plugins", "scope": "user", "enabled": False, "installPath": sys.argv[3] + "/plugins/example-core"}], open(sys.argv[2], "w"))
json.dump({"name": "example-core", "version": "1.0.0", "dependencies": ["example-ops"]}, open(sys.argv[4], "w"))
PY
run_doctor --fix
assert_contains "$DOCTOR_OUT" 'example-core@example-plugins requires example-ops@example-plugins' \
  "the disabled plugin dependency gap was not reported"
assert_not_contains "$(cat "$CASE_STATE/commands.log")" 'plugin enable' \
  "an uncatalogued dependency still enabled its configured plugin"
python3 - "$CASE_STATE/plugins.json" "$CASE_STATE/marketplace/plugins/example-core" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data == [{"id": "example-core@example-plugins", "scope": "user", "enabled": False, "installPath": sys.argv[2]}]
PY
pass "uncatalogued dependencies block plugin enable"

new_host
write_catalogue "$CASE_FM_HOME"
python3 - "$CASE_STATE/marketplaces.json" "$CASE_STATE/plugins.json" "$CASE_STATE/marketplace" <<'PY'
import json, sys
json.dump([{"name": "example-plugins", "source": "git", "url": "https://github.com/example/example-plugins.git", "installLocation": sys.argv[3]}], open(sys.argv[1], "w"))
json.dump([
    {"id": "example-core@example-plugins", "scope": "user", "enabled": True, "installPath": sys.argv[3] + "/plugins/example-core"},
    {"id": "example-ops@example-plugins", "scope": "user", "enabled": True},
    {"id": "example-disabled@example-plugins", "scope": "project", "enabled": False},
    {"id": "foreign@other-plugins", "scope": "user", "enabled": True},
], open(sys.argv[2], "w"))
PY
run_doctor
assert_contains "$DOCTOR_OUT" 'check host-plugins=human: installed plugin from a configured marketplace is not named' \
  "uncatalogued installed plugins were not reported"
assert_contains "$DOCTOR_OUT" 'example-ops@example-plugins' \
  "the uncatalogued enabled plugin was not named"
assert_contains "$DOCTOR_OUT" 'example-disabled@example-plugins' \
  "the uncatalogued disabled plugin was not named"
assert_not_contains "$DOCTOR_OUT" 'foreign@other-plugins' \
  "a plugin from an unconfigured marketplace was reported"
pass "installed plugins outside the configured marketplace allowlist are reported"

new_host
python3 - "$CASE_FM_HOME" "$CASE_STATE/marketplace" "$CASE_STATE/plugins.json" \
  "$CASE_STATE/marketplaces.json" "$CASE_STATE/details/example-domain@example-plugins" <<'PY'
import json, pathlib, sys
fm_home = pathlib.Path(sys.argv[1])
marketplace = pathlib.Path(sys.argv[2])
domain = marketplace / "plugins/example-domain/.claude-plugin"
domain.mkdir(parents=True)
fm_home.joinpath("config").mkdir()
json.dump({
    "marketplaces": [{"name": "example-plugins", "source": "https://github.com/example/example-plugins.git"}],
    "plugins": ["example-core@example-plugins", "example-domain@example-plugins"],
}, open(fm_home / "config/host-plugins.json", "w"))
json.dump({
    "name": "example-plugins",
    "plugins": [
        {"name": "example-core", "source": "./plugins/example-core"},
        {"name": "example-domain", "source": "./plugins/example-domain"},
    ],
}, open(marketplace / ".claude-plugin/marketplace.json", "w"))
json.dump({"name": "example-core", "dependencies": ["example-domain"]}, open(marketplace / "plugins/example-core/.claude-plugin/plugin.json", "w"))
json.dump({"name": "example-domain", "dependencies": []}, open(domain / "plugin.json", "w"))
json.dump([
    {"id": "example-core@example-plugins", "scope": "user", "enabled": True, "installPath": str(marketplace / "plugins/example-core")},
    {"id": "example-domain@example-plugins", "scope": "user", "enabled": True, "installPath": str(marketplace / "plugins/example-domain")},
], open(sys.argv[3], "w"))
json.dump([{
    "name": "example-plugins",
    "source": "git",
    "url": "https://github.com/example/example-plugins.git",
    "installLocation": str(marketplace),
}], open(sys.argv[4], "w"))
pathlib.Path(sys.argv[5]).write_text("example-domain 1.0.0\n  Skills (1)  example-domain-skill\n")
PY
run_doctor
assert_contains "$DOCTOR_OUT" 'check host-plugins=ok: configured Claude Code plugins resolve on this host' \
  "a fully catalogued plugin dependency was rejected"
pass "catalogued dependency closure remains launch-ready"
