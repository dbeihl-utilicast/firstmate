#!/usr/bin/env bash
# Pre-register Grok folder trust for a project PRIMARY checkout (not the task
# worktree) so a grok worker never wedges on the folder-trust dialog.
# See docs/verification/runtime-backends.md "Grok folder trust" for why.
set -u

unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

[ "$#" -eq 1 ] || { echo "usage: fm-grok-trust.sh <project>" >&2; exit 2; }
PROJ_ARG=$1

refuse() { echo "error: refusing to pre-register Grok trust: $1" >&2; exit 1; }

real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

common_dir_of() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd -P -- "$dir" && real_dir "$common")
}

PROJ_REAL=$(real_dir "$PROJ_ARG") || true
[ -n "$PROJ_REAL" ] || refuse "project '$PROJ_ARG' is not an accessible directory"

GROK_HOME_ARG=${GROK_HOME:-}
if [ -z "$GROK_HOME_ARG" ]; then
  [ -n "${HOME:-}" ] || refuse "neither GROK_HOME nor HOME is set, so the trust store cannot be located"
  GROK_HOME_ARG=$HOME/.grok
fi
GROK_HOME_REAL=$(real_dir "$GROK_HOME_ARG") || true
if [ -z "$GROK_HOME_REAL" ]; then
  mkdir -p "$GROK_HOME_ARG" 2>/dev/null || true
  GROK_HOME_REAL=$(real_dir "$GROK_HOME_ARG") || true
fi
[ -n "$GROK_HOME_REAL" ] || refuse "Grok home '$GROK_HOME_ARG' does not exist and could not be created"

validate_root() {
  local root=$1 top home_real
  [ "$root" != "$GROK_HOME_REAL" ] || refuse "'$root' is the Grok home directory, not a project checkout"
  if [ -n "${HOME:-}" ]; then
    home_real=$(real_dir "$HOME") || true
    [ "$root" != "${home_real:-}" ] || refuse "'$root' is the home directory, not a project checkout"
  fi
  top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || true
  [ -n "$top" ] || refuse "'$root' is not inside a git repository"
  top=$(real_dir "$top") || true
  [ "$top" = "$root" ] || refuse "'$root' is not a repository root (its root is '${top:-unresolvable}')"
}

validate_root "$PROJ_REAL"

PROJ_GIT_DIR=$(git -C "$PROJ_REAL" rev-parse --absolute-git-dir 2>/dev/null) || true
[ -n "$PROJ_GIT_DIR" ] || refuse "'$PROJ_REAL' has no resolvable git directory"
PROJ_GIT_DIR=$(real_dir "$PROJ_GIT_DIR") || true
[ -n "$PROJ_GIT_DIR" ] || refuse "'$PROJ_REAL' has an unresolvable git directory"
PROJ_COMMON=$(common_dir_of "$PROJ_REAL") || true
[ -n "$PROJ_COMMON" ] || refuse "'$PROJ_REAL' has no resolvable git common directory"
if [ "$PROJ_GIT_DIR" != "$PROJ_COMMON" ]; then
  IFS= read -r -d '' PRIMARY_RECORD < <(git -C "$PROJ_REAL" worktree list --porcelain -z 2>/dev/null) \
    || refuse "'$PROJ_REAL' has no resolvable primary checkout"
  case "$PRIMARY_RECORD" in
    'worktree '*) PRIMARY_REAL=$(real_dir "${PRIMARY_RECORD#worktree }") || true ;;
    *) refuse "'$PROJ_REAL' has no resolvable primary checkout" ;;
  esac
  [ -n "$PRIMARY_REAL" ] || refuse "'$PROJ_REAL' has no accessible primary checkout"
  validate_root "$PRIMARY_REAL"
  PRIMARY_GIT=$(git -C "$PRIMARY_REAL" rev-parse --absolute-git-dir 2>/dev/null) || true
  [ -n "$PRIMARY_GIT" ] && [ "$(real_dir "$PRIMARY_GIT")" = "$PROJ_COMMON" ] \
    || refuse "'$PRIMARY_REAL' is not the primary checkout of '$PROJ_REAL'"
  PROJ_REAL=$PRIMARY_REAL
fi

command -v node >/dev/null 2>&1 || refuse "node is required to record folder trust and was not found on PATH"

STORE="$GROK_HOME_REAL/trusted_folders.toml"
if ! (
  FM_STATE_OVERRIDE=$GROK_HOME_REAL
  # shellcheck source=bin/fm-wake-lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/fm-wake-lib.sh"
  TRUST_LOCK="$STORE.fm-lock"
  fm_lock_acquire_wait_bounded "$TRUST_LOCK" 10 || refuse "could not acquire the trust-store lock for '$STORE'"
  trap 'fm_lock_release "$TRUST_LOCK"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [ ! -L "$STORE" ] || refuse "'$STORE' is a symlink; a regular trust file is required"
  if [ -e "$STORE" ]; then
    [ -f "$STORE" ] || refuse "'$STORE' is not a regular file"
    [ -O "$STORE" ] || refuse "'$STORE' is not owned by this user"
    [ -w "$STORE" ] || refuse "'$STORE' is not writable"
  fi

  node - "$STORE" "$PROJ_REAL" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [store, target] = process.argv.slice(2);

const escape = (s) => s.replace(/\\/g, "\\\\").replace(/"/g, '\\"');

function findBlock(text, target) {
  const re = /^\[folders\."((?:[^"\\]|\\.)*)"\]\r?\n/gm;
  const headers = [];
  let m;
  while ((m = re.exec(text)) !== null) {
    headers.push({ index: m.index, bodyStart: re.lastIndex, raw: m[1] });
  }
  for (let i = 0; i < headers.length; i += 1) {
    const unescaped = headers[i].raw.replace(/\\(.)/g, "$1");
    if (unescaped !== target) continue;
    const bodyEnd = i + 1 < headers.length ? headers[i + 1].index : text.length;
    return { body: text.slice(headers[i].bodyStart, bodyEnd) };
  }
  return null;
}

const readStore = () => {
  try {
    return fs.readFileSync(store);
  } catch (err) {
    if (err.code === "ENOENT") return null;
    throw err;
  }
};
const fingerprint = (buf) => (buf === null ? "absent" : crypto.createHash("sha256").update(buf).digest("hex"));

const attempt = () => {
  const original = readStore();
  const before = fingerprint(original);
  const text = original === null ? "" : original.toString("utf8");
  const existing = findBlock(text, target);
  if (existing) {
    if (/^[ \t]*trusted[ \t]*=[ \t]*true[ \t]*$/m.test(existing.body)) return "already-trusted";
    if (/^[ \t]*trusted[ \t]*=[ \t]*false[ \t]*$/m.test(existing.body)) {
      throw new Error(`${target} already has an explicit untrust decision in ${store}; refusing to override it`);
    }
    throw new Error(`${target} already has an unrecognized trust entry in ${store}; refusing to touch it`);
  }
  const sep = text.length === 0 || text.endsWith("\n\n") ? "" : text.endsWith("\n") ? "\n" : "\n\n";
  const block = `[folders."${escape(target)}"]\ntrusted = true\n`;
  const next = text + sep + block;
  const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  const tmp = path.join(path.dirname(store), `.trusted_folders.toml.fm-trust.${unique}`);
  fs.writeFileSync(tmp, next, { mode: 0o600, flag: "wx" });
  let renamed = false;
  try {
    if (fingerprint(readStore()) !== before) return "moved";
    fs.renameSync(tmp, store);
    renamed = true;
  } finally {
    if (!renamed) fs.rmSync(tmp, { force: true });
  }
  const back = fs.readFileSync(store, "utf8");
  const backBlock = findBlock(back, target);
  return backBlock && /^[ \t]*trusted[ \t]*=[ \t]*true[ \t]*$/m.test(backBlock.body) ? "recorded" : "dropped";
};

try {
  for (let i = 0; i < 3; i += 1) {
    const result = attempt();
    if (result === "recorded" || result === "already-trusted") {
      const label = result === "recorded" ? "trusted" : "already-trusted";
      process.stdout.write(`${label}: ${target}\n`);
      process.exit(0);
    }
    if (result === "moved" && i >= 1) {
      console.error(`error: ${store} was modified while trust was being recorded; refusing to overwrite it`);
      process.exit(1);
    }
  }
} catch (err) {
  console.error(`error: ${err.message}`);
  process.exit(1);
}
console.error(`error: ${store} did not retain trust for ${target} after 3 attempts`);
process.exit(1);
NODE
)
then
  refuse "could not record trust for '$PROJ_REAL' in '$STORE'"
fi
