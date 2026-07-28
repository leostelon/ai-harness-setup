#!/bin/sh
# Contract for the sandbox-wide zipbox skill installation.
#
# This test runs as root on the disposable GitHub runner because the production
# path is deliberately fixed at /root/skills. Network access is replaced with a
# local tarball through a fixture curl binary.
set -eu

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
EXPECTED="zipbox-browser
zipbox-caddy
zipbox-dns
zipbox-email
zipbox-wallet
zipbox-websearch
zipbox-x.com"

fail() {
  printf 'FAIL - %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "$3 (got '$1', expected '$2')"
}

actual_catalog="$(
  find "$REPO/skills" -mindepth 1 -maxdepth 1 -type d -name 'zipbox-*' \
    -exec test -f '{}/SKILL.md' \; -printf '%f\n' | sort
)"
assert_eq "$actual_catalog" "$EXPECTED" "repository zipbox catalog"

for path in /root/skills /root/.agent-skills /root/.claude /root/.pi /root/.openclaw; do
  if [ -e "$path" ] || [ -L "$path" ]; then
    fail "test requires a clean disposable runner: $path already exists"
  fi
done

TMP_ROOT="$(mktemp -d)"
cleanup() {
  chmod -R u+rwX /root/skills /root/.agent-skills /root/.claude /root/.pi /root/.openclaw \
    2>/dev/null || true
  rm -rf /root/skills /root/.agent-skills /root/.claude /root/.pi /root/.openclaw
  rm -f /root/workspace/AGENTS.md
  rmdir /root/workspace 2>/dev/null || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$TMP_ROOT/repo/skills" "$TMP_ROOT/bin"
cp -R "$REPO/skills/." "$TMP_ROOT/repo/skills/"
tar -czf "$TMP_ROOT/repo.tgz" -C "$TMP_ROOT" repo

cat > "$TMP_ROOT/bin/curl" <<'EOF'
#!/bin/sh
set -eu
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      shift
      out="${1:-}"
      ;;
  esac
  shift
done
[ -n "$out" ]
cp "$FIXTURE_TGZ" "$out"
EOF
chmod +x "$TMP_ROOT/bin/curl"

mkdir -p \
  /root/skills/local-user \
  /root/skills/zipbox-stale \
  /root/.agent-skills/zipbox-stale \
  /root/.claude \
  /root/.pi/agent/skills/local-trading \
  /root/.pi/agent/skills/zipbox-stale \
  /root/.openclaw \
  /root/workspace
printf '%s\n' 'local user skill' > /root/skills/local-user/SKILL.md
printf '%s\n' 'local trading skill' > /root/.pi/agent/skills/local-trading/SKILL.md
printf '%s\n' 'stale' > /root/skills/zipbox-stale/SKILL.md
printf '%s\n' 'stale' > /root/.agent-skills/zipbox-stale/SKILL.md
printf '%s\n' 'stale' > /root/.pi/agent/skills/zipbox-stale/SKILL.md
ln -s /root/.agent-skills /root/.openclaw/skills
printf '%s\n' '# Existing harness instructions' > /root/workspace/AGENTS.md

export FIXTURE_TGZ="$TMP_ROOT/repo.tgz"
PATH="$TMP_ROOT/bin:$PATH"
export PATH

run_installer() {
  HOME=/root \
    TRIBES_HARNESS_REPO=https://example.invalid/fixture \
    TRIBES_HARNESS_REF=test \
    sh "$REPO/install-skills.sh"
}

run_installer

installed_catalog="$(
  find /root/skills -mindepth 1 -maxdepth 1 -type d -name 'zipbox-*' \
    -exec test -f '{}/SKILL.md' \; -printf '%f\n' | sort
)"
assert_eq "$installed_catalog" "$EXPECTED" "installed zipbox catalog"
assert_eq "$(stat -c '%a' /root/skills)" "555" "/root/skills mode"

for slug in $EXPECTED; do
  [ -z "$(find "/root/skills/$slug" -type d ! -perm 0555 -print -quit)" ] \
    || fail "$slug contains a writable directory"
  [ -z "$(find "/root/skills/$slug" -type f ! -perm 0444 -print -quit)" ] \
    || fail "$slug contains a writable file"
done

[ -f /root/skills/local-user/SKILL.md ] || fail "canonical update removed a non-zipbox skill"
[ ! -e /root/skills/zipbox-stale ] || fail "canonical update left a stale zipbox skill"
[ ! -e /root/.agent-skills ] || fail "legacy managed skill directory remains"

[ -L /root/.claude/skills ] || fail "claude skills path is not a symlink"
assert_eq "$(readlink /root/.claude/skills)" "/root/skills" "claude symlink target"
[ -L /root/.openclaw/skills ] || fail "openclaw skills path is not a symlink"
assert_eq "$(readlink /root/.openclaw/skills)" "/root/skills" "openclaw symlink target"

[ -d /root/.pi/agent/skills ] && [ ! -L /root/.pi/agent/skills ] \
  || fail "existing Pi skills directory was replaced"
[ -f /root/.pi/agent/skills/local-trading/SKILL.md ] \
  || fail "Pi non-zipbox skill was removed"
[ ! -e /root/.pi/agent/skills/zipbox-stale ] \
  || fail "Pi stale zipbox entry remains"
for slug in $EXPECTED; do
  link="/root/.pi/agent/skills/$slug"
  [ -L "$link" ] || fail "$link is not a symlink"
  assert_eq "$(readlink "$link")" "/root/skills/$slug" "$slug Pi symlink target"
done

assert_eq "$(grep -c '<!-- BEGIN TRIBES SKILLS -->' /root/workspace/AGENTS.md)" "1" \
  "AGENTS skills block count"
for slug in $EXPECTED; do
  assert_eq "$(grep -cF -- "- **$slug**" /root/workspace/AGENTS.md)" "1" \
    "$slug AGENTS route count"
  grep -F "Read: /root/skills/$slug/SKILL.md" /root/workspace/AGENTS.md >/dev/null \
    || fail "$slug AGENTS route does not use the canonical path"
done
if grep -F '— >- Read:' /root/workspace/AGENTS.md >/dev/null; then
  fail "AGENTS routes contain an unparsed folded-description marker"
fi

snapshot() {
  find /root/skills /root/.claude/skills /root/.pi/agent/skills /root/.openclaw/skills \
    -printf '%p|%y|%m|%l\n' | sort
  find /root/skills -type f -exec sha256sum {} \; | sort
}

snapshot > "$TMP_ROOT/before.snapshot"
cp /root/workspace/AGENTS.md "$TMP_ROOT/before.AGENTS.md"
run_installer
snapshot > "$TMP_ROOT/after.snapshot"

cmp "$TMP_ROOT/before.snapshot" "$TMP_ROOT/after.snapshot" >/dev/null \
  || fail "second install changed paths, modes, targets, or content"
cmp "$TMP_ROOT/before.AGENTS.md" /root/workspace/AGENTS.md >/dev/null \
  || fail "second install changed the AGENTS routing block"

printf '%s\n' 'ok - shared skills installation contract'
