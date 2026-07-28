#!/bin/sh
# Drive-first contract for the shared agent PRIMER.
#
# The terminal repo's dockers/Dockerfile.harnesses vendors this whole repo onto
# the shared read-only drive at /opt/harnesses/templates (+ a .version stamp), so
# a stock first switch seeds AGENTS.md + render-primer.sh from the drive instead
# of curling raw.githubusercontent. This test runs the real primer block from the
# real bootstrap.sh files with a DEAD NETWORK and pins:
#
#   1. every harness carries the block, and all nine are the SAME block (modulo
#      claude's CLAUDE.md mirror flag) — a harness silently left on the curl path
#      is the whole failure mode
#   2. stock path (no TRIBES_HARNESS_REF): seeds from the drive, ZERO network
#      attempts, and the DRIVE's renderer is the one that runs
#   3. pinned TRIBES_HARNESS_REF (QA): the fetch IS attempted, so a pinned box
#      exercises the ref it pinned rather than the drive's copy
#   4. no templates on the drive (pre-rollout image / dev backend): the fetch is
#      attempted — the drive is an optimisation, never a requirement
#   5. no bootstrap installs a package over the network at switch time
set -eu

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DRIVE=/opt/harnesses/templates
HARNESSES="claude cline codex cursor grok hermes openclaw opencode pi"

fail() {
  printf 'FAIL - %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "$3 (got '$1', expected '$2')"
}

for path in /opt/harnesses /opt/tribes; do
  if [ -e "$path" ] || [ -L "$path" ]; then
    fail "test requires a clean disposable runner: $path already exists"
  fi
done

TMP_ROOT="$(mktemp -d)"
cleanup() {
  rm -rf /opt/harnesses /opt/tribes "$TMP_ROOT"
}
trap cleanup EXIT HUP INT TERM

# The primer block, lifted verbatim from a bootstrap.sh: from the /opt/tribes
# mkdir through the `fi` that closes the render branch.
extract_primer() {
  awk '
    /^mkdir -p \/opt\/tribes 2>\/dev\/null \|\| true$/ { p = 1 }
    p                                                  { print }
    /primer NOT rendered/                              { seen = 1 }
    seen && /^fi$/                                     { exit }
  ' "$1"
}

# --- 1. every harness carries the SAME block --------------------------------
extract_primer "$REPO/claude/bootstrap.sh" > "$TMP_ROOT/claude.block"
[ -s "$TMP_ROOT/claude.block" ] || fail "claude/bootstrap.sh has no primer block to extract"
grep -q '/opt/harnesses/templates/render-primer.sh' "$TMP_ROOT/claude.block" \
  || fail "the extracted block is not the drive-first one"

# claude mirrors the primer into CLAUDE.md and says so in a comment; normalise
# both away and the nine blocks must be byte-identical.
normalise() {
  sed -e 's/^  TRIBES_PRIMER_ALSO_CLAUDE_MD=1 sh /  sh /' \
      -e 's/^# obvious\. claude also reads CLAUDE\.md.*$/# obvious./' "$1"
}
normalise "$TMP_ROOT/claude.block" > "$TMP_ROOT/reference.block"

for harness in $HARNESSES; do
  extract_primer "$REPO/$harness/bootstrap.sh" > "$TMP_ROOT/$harness.block"
  [ -s "$TMP_ROOT/$harness.block" ] || fail "$harness/bootstrap.sh has no primer block"
  normalise "$TMP_ROOT/$harness.block" > "$TMP_ROOT/$harness.normalised"
  cmp "$TMP_ROOT/reference.block" "$TMP_ROOT/$harness.normalised" >/dev/null \
    || fail "$harness/bootstrap.sh primer block diverged from the others"
done
assert_eq "$(grep -c 'TRIBES_PRIMER_ALSO_CLAUDE_MD=1' "$TMP_ROOT/claude.block")" "1" \
  "claude must keep its CLAUDE.md mirror flag"
for harness in cline codex cursor grok hermes openclaw opencode pi; do
  assert_eq "$(grep -c 'TRIBES_PRIMER_ALSO_CLAUDE_MD' "$TMP_ROOT/$harness.block")" "0" \
    "$harness must not set the CLAUDE.md mirror flag"
done

# --- dead network + a drive whose renderer leaves a fingerprint --------------
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

seed_drive() {
  mkdir -p "$DRIVE"
  printf '%s\n' '# Primer __HOST__' > "$DRIVE/AGENTS.md"
  cat > "$DRIVE/render-primer.sh" <<EOF
#!/bin/sh
printf 'drive\n' > "$TMP_ROOT/rendered-by"
EOF
  chmod 0755 "$DRIVE/render-primer.sh"
}

# $1 = TRIBES_HARNESS_REF ('' = unset, i.e. a stock box), $2 = the REF the
# surrounding bootstrap.sh would have resolved. RAW_BASE/REF are assigned by the
# lines just above the extracted block, so the runner supplies them.
run_primer() {
  rm -rf /opt/tribes
  rm -f "$TMP_ROOT/rendered-by"
  {
    printf 'RAW_BASE=%s\n' 'https://raw.githubusercontent.com/tribes-protocol/ai-harness-setup'
    printf 'REF=%s\n' "$2"
    cat "$TMP_ROOT/claude.block"
  } > "$TMP_ROOT/run.sh"
  if [ -n "$1" ]; then
    TRIBES_HARNESS_REF="$1" sh "$TMP_ROOT/run.sh"
  else
    env -u TRIBES_HARNESS_REF sh "$TMP_ROOT/run.sh"
  fi
}

# --- 2. stock: drive-first, zero network ------------------------------------
seed_drive
run_primer '' main
assert_eq "$(curl_attempts)" "0" "stock first switch must not touch the network"
[ -f /opt/tribes/AGENTS.md.tmpl ] || fail "stock path did not seed AGENTS.md.tmpl"
[ -x /opt/tribes/render-primer.sh ] || fail "stock path did not seed an executable renderer"
assert_eq "$(cat "$TMP_ROOT/rendered-by" 2>/dev/null || echo none)" "drive" \
  "the renderer that ran must be the DRIVE's copy"
cmp "$DRIVE/AGENTS.md" /opt/tribes/AGENTS.md.tmpl >/dev/null \
  || fail "the seeded primer is not the drive's copy"

# --- 3. a QA pin must exercise its own ref, not the drive -------------------
run_primer 0123456789abcdef0123456789abcdef01234567 0123456789abcdef0123456789abcdef01234567
[ "$(curl_attempts)" -ge 1 ] || fail "a pinned TRIBES_HARNESS_REF must attempt the fetch"
[ ! -e "$TMP_ROOT/rendered-by" ] || fail "a pinned ref fell back to the drive's renderer"

# --- 4. a drive with no templates still works (over the network) ------------
rm -rf /opt/harnesses
before="$(curl_attempts)"
run_primer '' main
[ "$(curl_attempts)" -gt "$before" ] || fail "a drive without templates must fall back to the fetch"

# --- 5. no bootstrap fetches a dependency at switch time ---------------------
# codex used to `bun add smol-toml` on the BYO path — a network install on the
# one flow that is supposed to have nothing left to install. Its awk fallback,
# already shipping, is now the only strip path. The `npm install -g` behind each
# harness's `command -v` gate stays: that is the safety net for a broken drive,
# and the terminal-side bake gates now make an empty delta fail loudly instead.
for harness in $HARNESSES; do
  # Comment lines are excluded — codex explains the removal in one.
  if grep -v '^[[:space:]]*#' "$REPO/$harness/bootstrap.sh" | grep -q 'bun add'; then
    fail "$harness/bootstrap.sh installs a dependency over the network at switch time"
  fi
done

printf '%s\n' 'ok - drive-first primer contract'
