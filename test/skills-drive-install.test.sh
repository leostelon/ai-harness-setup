#!/bin/sh
# Drive-first contract for the sandbox-wide zipbox skill installation (#1914).
#
# The terminal repo's dockers/Dockerfile.harnesses bakes skills/<slug>/ and
# install-skills.sh onto the shared read-only drive at /opt/harnesses/skills
# (0444 files / 0555 dirs). This test simulates that bake on the disposable
# GitHub runner (as root — the production paths are deliberately fixed at
# /opt/harnesses/skills and /root/skills) with a DEAD network (a curl fixture
# that records every attempt and fails), and pins:
#
#   1. stock path (no template pin): installs by symlinking the baked catalog
#      into /root/skills WITHOUT any network attempt, replacing prior copies,
#      keeping unrelated local skills, and wiring loaders + AGENTS routes
#   2. re-run: fully idempotent, still no network attempt
#   3. pinned TRIBES_HARNESS_REF + fetch fails + complete install in place:
#      the fetch is attempted, and the existing installation is kept untouched
#   4. pinned TRIBES_HARNESS_REF + fetch fails + INCOMPLETE install: the drive
#      fallback reconverges the catalog
set -eu

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DRIVE=/opt/harnesses/skills
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

for path in /opt/harnesses /root/skills /root/.agent-skills /root/.claude /root/.pi /root/.openclaw; do
  if [ -e "$path" ] || [ -L "$path" ]; then
    fail "test requires a clean disposable runner: $path already exists"
  fi
done

TMP_ROOT="$(mktemp -d)"
cleanup() {
  chmod -R u+rwX /opt/harnesses /root/skills /root/.claude /root/.pi /root/.openclaw \
    2>/dev/null || true
  rm -rf /opt/harnesses /root/skills /root/.agent-skills /root/.claude /root/.pi /root/.openclaw
  rm -f /root/workspace/AGENTS.md
  rmdir /root/workspace 2>/dev/null || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT HUP INT TERM

# --- simulate the drive bake (Dockerfile.harnesses layout + modes) ----------
mkdir -p "$DRIVE"
cp -R "$REPO/skills/." "$DRIVE/"
cp "$REPO/install-skills.sh" "$DRIVE/install-skills.sh"
printf '%s\n' 'test-bake-ref' > "$DRIVE/.version"
find "$DRIVE" -type f -exec chmod 0444 {} +
find "$DRIVE" -type d -exec chmod 0555 {} +
chmod 0555 "$DRIVE/install-skills.sh"

# --- dead network: a curl that records the attempt and fails ----------------
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/curl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP_ROOT/curl-attempts"
exit 1
EOF
chmod +x "$TMP_ROOT/bin/curl"
PATH="$TMP_ROOT/bin:$PATH"
export PATH

curl_attempts() {
  [ -f "$TMP_ROOT/curl-attempts" ] && wc -l < "$TMP_ROOT/curl-attempts" | tr -d ' ' || echo 0
}

# --- pre-seed a pre-rollout state the drive install must converge -----------
mkdir -p \
  /root/skills/local-user \
  /root/skills/zipbox-stale \
  /root/skills/zipbox-browser \
  /root/.claude \
  /root/.pi/agent/skills/local-trading \
  /root/.openclaw \
  /root/workspace
printf '%s\n' 'local user skill' > /root/skills/local-user/SKILL.md
printf '%s\n' 'stale' > /root/skills/zipbox-stale/SKILL.md
printf '%s\n' 'pre-drive fetched copy' > /root/skills/zipbox-browser/SKILL.md
printf '%s\n' 'local trading skill' > /root/.pi/agent/skills/local-trading/SKILL.md
printf '%s\n' '# Existing harness instructions' > /root/workspace/AGENTS.md

# --- 1. stock path: baked installer, no pin, dead network -------------------
HOME=/root sh "$DRIVE/install-skills.sh"

assert_eq "$(curl_attempts)" "0" "stock drive-first path must not touch the network"

installed_catalog="$(
  find /root/skills -mindepth 1 -maxdepth 1 -name 'zipbox-*' \
    -exec test -e '{}/SKILL.md' \; -printf '%f\n' | sort
)"
assert_eq "$installed_catalog" "$EXPECTED" "installed zipbox catalog"
[ ! -L /root/skills ] || fail "/root/skills must stay a real directory"
assert_eq "$(stat -c '%a' /root/skills)" "555" "/root/skills mode"

for slug in $EXPECTED; do
  [ -L "/root/skills/$slug" ] || fail "$slug is not a symlink to the drive"
  assert_eq "$(readlink "/root/skills/$slug")" "$DRIVE/$slug" "$slug symlink target"
  [ -z "$(find -L "/root/skills/$slug" -type d ! -perm 0555 -print -quit)" ] \
    || fail "$slug resolves to a writable directory"
  [ -z "$(find -L "/root/skills/$slug" -type f ! -perm 0444 -print -quit)" ] \
    || fail "$slug resolves to a writable file"
done

[ -f /root/skills/local-user/SKILL.md ] || fail "drive install removed a non-zipbox skill"
[ ! -e /root/skills/zipbox-stale ] || fail "drive install left a stale zipbox skill"

[ -L /root/.claude/skills ] || fail "claude skills path is not a symlink"
assert_eq "$(readlink /root/.claude/skills)" "/root/skills" "claude symlink target"
[ -L /root/.openclaw/skills ] || fail "openclaw skills path is not a symlink"
assert_eq "$(readlink /root/.openclaw/skills)" "/root/skills" "openclaw symlink target"
[ -d /root/.pi/agent/skills ] && [ ! -L /root/.pi/agent/skills ] \
  || fail "existing Pi skills directory was replaced"
[ -f /root/.pi/agent/skills/local-trading/SKILL.md ] \
  || fail "Pi non-zipbox skill was removed"
for slug in $EXPECTED; do
  link="/root/.pi/agent/skills/$slug"
  [ -L "$link" ] || fail "$link is not a symlink"
  assert_eq "$(readlink "$link")" "/root/skills/$slug" "$slug Pi symlink target"
done

assert_eq "$(grep -c '<!-- BEGIN TRIBES SKILLS -->' /root/workspace/AGENTS.md)" "1" \
  "AGENTS skills block count"
for slug in $EXPECTED; do
  grep -F "Read: /root/skills/$slug/SKILL.md" /root/workspace/AGENTS.md >/dev/null \
    || fail "$slug AGENTS route does not use the canonical path"
done

# --- 2. re-run: idempotent, still no network --------------------------------
snapshot() {
  find /root/skills /root/.claude/skills /root/.pi/agent/skills /root/.openclaw/skills \
    -printf '%p|%y|%m|%l\n' | sort
}

snapshot > "$TMP_ROOT/before.snapshot"
cp /root/workspace/AGENTS.md "$TMP_ROOT/before.AGENTS.md"
HOME=/root sh "$DRIVE/install-skills.sh"
snapshot > "$TMP_ROOT/after.snapshot"

assert_eq "$(curl_attempts)" "0" "drive-first re-run must not touch the network"
cmp "$TMP_ROOT/before.snapshot" "$TMP_ROOT/after.snapshot" >/dev/null \
  || fail "second install changed paths, modes, or targets"
cmp "$TMP_ROOT/before.AGENTS.md" /root/workspace/AGENTS.md >/dev/null \
  || fail "second install changed the AGENTS routing block"

# --- 3. pinned ref + dead network + complete install: keep it ---------------
HOME=/root TRIBES_HARNESS_REF=test sh "$DRIVE/install-skills.sh"
snapshot > "$TMP_ROOT/pinned.snapshot"

[ "$(curl_attempts)" -ge 1 ] || fail "a pinned ref must attempt the fetch"
cmp "$TMP_ROOT/before.snapshot" "$TMP_ROOT/pinned.snapshot" >/dev/null \
  || fail "pinned failed fetch replaced a complete installation"

# --- 4. pinned ref + dead network + incomplete install: drive fallback ------
chmod u+w /root/skills
rm /root/skills/zipbox-email
chmod 0555 /root/skills
HOME=/root TRIBES_HARNESS_REF=test sh "$DRIVE/install-skills.sh"

[ -L /root/skills/zipbox-email ] || fail "drive fallback did not restore the missing slug"
assert_eq "$(readlink /root/skills/zipbox-email)" "$DRIVE/zipbox-email" \
  "restored slug symlink target"
snapshot > "$TMP_ROOT/fallback.snapshot"
cmp "$TMP_ROOT/before.snapshot" "$TMP_ROOT/fallback.snapshot" >/dev/null \
  || fail "drive fallback did not reconverge on the baked catalog"

printf '%s\n' 'ok - drive-first skills installation contract'
