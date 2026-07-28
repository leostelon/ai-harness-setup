#!/bin/sh
# Runtime supply-chain contract for the in-guest bootstrap/launch scripts (#2948),
# and the ref-pin contract they resolve their own-repo fetches with (#2937).
#
# WHY THIS EXISTS, AND WHY IT LIVES HERE
#
# tribes-protocol/terminal closed the BAKE surface (#2947) and guards it with
# scripts/test/bake-supply-chain-pins.test.sh. That guard covers
# dockers/Dockerfile.{sandbox,harnesses} and scripts/bake-*.sh, and it CANNOT SEE
# THIS REPOSITORY. The same three vendor installers also ran at RUNTIME, in the
# guest, as root, from these scripts — outside every digest gate. A fix here needs
# a guard here, or the next edit silently re-opens it.
#
# WHAT MAKES THE RUNTIME PATH REACHABLE (it is not dead code)
#
# Each vendor installer is gated on `command -v <bin>` failing first, so with a
# populated /opt/harnesses delta the branch is unreachable. But that gate is
# EXACTLY the condition an empty delta produces, and an empty delta is a known
# failure mode. On such a box every one of these fired — unauthenticated,
# unpinned, as root, on the first switch to that harness.
#
# THE SHAPE OF THIS FILE
#
# Sections 1-5 are static assertions, each with a positive control on its own scan
# so a rename or a moved file degrades to a LOUD failure rather than a vacuous
# pass. Section 6 is different in kind and is the point of the file: it EXECUTES
# the real installer block against a tampered artifact and proves the digest gate
# fires and refuses the install. A grep proves a line exists; only an execution
# proves it runs.
set -u

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
HARNESSES='claude cline codex cursor grok hermes openclaw opencode pi'

fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1" >&2; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# =============================================================================
# 0. Positive control on the whole file: the tree is where we think it is.
#    Without this every loop below could iterate zero times and "pass".
# =============================================================================
n=0
for h in $HARNESSES; do
  [ -f "$REPO/$h/bootstrap.sh" ] || fail "missing $h/bootstrap.sh"
  [ -f "$REPO/$h/launch.sh" ] || fail "missing $h/launch.sh"
  n=$((n + 1))
done
[ "$n" -eq 9 ] || fail "expected 9 harnesses, iterated $n"
[ -f "$REPO/install-skills.sh" ] || fail "missing install-skills.sh"
[ "$fails" -eq 0 ] && pass "harness tree present (9 harnesses x {bootstrap,launch}.sh + install-skills.sh)"

# =============================================================================
# 1. No `curl | shell` anywhere on the runtime path.
#    A truncated transfer piped to a shell EXECUTES the bytes that arrived —
#    there is no atomicity. Download to a file, verify, then run the file.
#    The pattern deliberately allows an env prefix (`| HOME=… bash`, which is how
#    two of the three original offenders were written) so a re-add cannot dodge
#    the guard by inserting an assignment.
# =============================================================================
scanned=0
fails_before=$fails
for f in "$REPO"/*/bootstrap.sh "$REPO"/*/launch.sh "$REPO/install-skills.sh" "$REPO/render-primer.sh"; do
  scanned=$((scanned + 1))
  name="${f#$REPO/}"
  # Strip comments first: this file and the scripts themselves discuss `curl | sh`
  # in prose, and a guard that its own rationale trips is a guard nobody keeps.
  if sed 's/[[:space:]]*#.*$//' "$f" | grep -qE 'curl.*\|[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(ba)?sh([[:space:]]|$)'; then
    fail "$name pipes curl into a shell — download, verify, then execute (#2948)"
  fi
done
[ "$scanned" -eq 20 ] || fail "curl-pipe scan covered $scanned files, expected 20"
[ "$fails" -eq "$fails_before" ] && pass "no curl|shell on the runtime path ($scanned files scanned)"

# =============================================================================
# 2. Every own-repo fetch resolves an IMMUTABLE ref, never `main` (#2937).
#    `main` routes around the release pin — which is the entire purpose of the
#    pin — and the `|| true` downstream makes a swap silent in either direction.
#    The resolution order is guest pin -> host pin -> the last reviewed release.
# =============================================================================
scanned=0
fails_before=$fails
for f in "$REPO"/*/bootstrap.sh "$REPO"/*/launch.sh "$REPO/install-skills.sh" "$REPO/render-primer.sh"; do
  scanned=$((scanned + 1))
  name="${f#$REPO/}"
  if grep -qE '(TRIBES|HOST)_HARNESS_REF:-main\}' "$f"; then
    fail "$name defaults a ref to the mutable branch 'main' (#2937)"
  fi
done
[ "$scanned" -eq 20 ] || fail "mutable-ref scan covered $scanned files, expected 20"
[ "$fails" -eq "$fails_before" ] && pass "no fetch defaults to a mutable branch ($scanned files scanned)"

# =============================================================================
# 3. The release-pin literal is a 40-hex SHA and IDENTICAL everywhere.
#    It is necessarily duplicated: a script needs the ref in order to fetch
#    anything, so it cannot read the ref from something it fetches. Duplication is
#    therefore accepted and the DRIFT is what gets locked.
# =============================================================================
pins="$(grep -rhoE 'HOST_HARNESS_REF:-[0-9a-f]{40}\}' \
  "$REPO"/*/bootstrap.sh "$REPO"/*/launch.sh "$REPO/install-skills.sh" "$REPO/render-primer.sh" |
  sed 's/HOST_HARNESS_REF:-//; s/}$//' | sort -u)"
pin_count="$(printf '%s\n' "$pins" | grep -c '^[0-9a-f]\{40\}$')"
sites="$(grep -rhoE 'HOST_HARNESS_REF:-[0-9a-f]{40}\}' \
  "$REPO"/*/bootstrap.sh "$REPO"/*/launch.sh "$REPO/install-skills.sh" "$REPO/render-primer.sh" | wc -l | tr -d ' ')"

if [ "$pin_count" -ne 1 ]; then
  fail "expected ONE distinct release pin across the tree, found $pin_count: $(printf '%s' "$pins" | tr '\n' ' ')"
elif [ "$sites" -lt 20 ]; then
  # 9 bootstrap.sh (primer REF) + 9 launch.sh (SKILLS_REF) + install-skills.sh +
  # render-primer.sh. Fewer means a site lost its pin — the scan is the control.
  fail "expected at least 20 pinned ref sites, found $sites — a site lost its pin"
else
  pass "one release pin ($pins) used identically at $sites sites"
fi

# =============================================================================
# 4. install-skills.sh's completeness contract.
#    Its consumers verify a fetched copy is COMPLETE by requiring the last line to
#    be a literal `exit 0` before executing it — that is what makes a truncated
#    download detectable without a per-release digest. If this file stops ending
#    that way, every consumer silently stops installing skills. Lock both halves.
# =============================================================================
last="$(tail -n 1 "$REPO/install-skills.sh")"
if [ "$last" = "exit 0" ]; then
  pass "install-skills.sh ends with the literal 'exit 0' its consumers require"
else
  fail "install-skills.sh must end with a literal 'exit 0' (consumers use it as the completeness check); last line is '$last'"
fi

consumers=0
for f in "$REPO"/*/bootstrap.sh "$REPO"/*/launch.sh; do
  name="${f#$REPO/}"
  grep -q 'tail -n 1' "$f" && consumers=$((consumers + 1)) ||
    fail "$name fetches install-skills.sh without the completeness check"
done
[ "$consumers" -eq 18 ] || fail "expected 18 completeness-checking consumers, found $consumers"
[ "$consumers" -eq 18 ] && pass "all 18 consumers verify the installer is complete before executing it"

# =============================================================================
# 5. Each vendor installer carries a digest pin, and the check PRECEDES execution.
#    hermes is deliberately different and that difference is asserted, not
#    papered over: it has NO version-addressed artifact (its install.sh git-clones
#    NousResearch/hermes-agent, builds a venv from PyPI, and pulls uv + node), so
#    the achievable pin is the INSTALLER SCRIPT ONLY. That proves the script which
#    runs as root is the script a human reviewed; it does NOT bind the tree that
#    script then installs.
# =============================================================================
check_vendor() {
  h="$1"; var="$2"; f="$REPO/$h/bootstrap.sh"
  if ! grep -qE "^${var}=[0-9a-f]{64}\$" "$f"; then
    fail "$h/bootstrap.sh has no pinned $var (64-hex sha256)"
    return
  fi
  if ! grep -q 'sha256sum -c -' "$f"; then
    fail "$h/bootstrap.sh never verifies a digest"
    return
  fi
  # Order matters: verification must gate execution, not follow it.
  vline="$(grep -n 'sha256sum -c -' "$f" | head -1 | cut -d: -f1)"
  case "$h" in
    grok)   rline="$(grep -n 'install -m 0755' "$f" | head -1 | cut -d: -f1)" ;;
    cursor) rline="$(grep -n 'tar --strip-components' "$f" | head -1 | cut -d: -f1)" ;;
    hermes) rline="$(grep -n 'script -qec' "$f" | head -1 | cut -d: -f1)" ;;
  esac
  if [ -z "${rline:-}" ]; then
    fail "$h/bootstrap.sh: cannot locate the execution step — this scan is broken, not the file"
  elif [ "$vline" -ge "$rline" ]; then
    fail "$h/bootstrap.sh verifies the digest AFTER using the artifact (line $vline >= $rline)"
  else
    pass "$h pins $var and verifies it before use (check line $vline, use line $rline)"
  fi
}
check_vendor grok GROK_SHA256
check_vendor cursor CURSOR_SHA256
check_vendor hermes HERMES_INSTALLER_SHA256

# grok and cursor must fetch a VERSION-ADDRESSED artifact, not a script.
grep -qE '^GROK_VERSION=' "$REPO/grok/bootstrap.sh" &&
  grep -q 'x.ai/cli/grok-${GROK_VERSION}-linux-x86_64' "$REPO/grok/bootstrap.sh" &&
  pass "grok fetches the version-addressed binary, not install.sh" ||
  fail "grok must fetch https://x.ai/cli/grok-\${GROK_VERSION}-linux-x86_64"

grep -qE '^CURSOR_VERSION=' "$REPO/cursor/bootstrap.sh" &&
  grep -q 'downloads.cursor.com/lab/${CURSOR_VERSION}' "$REPO/cursor/bootstrap.sh" &&
  pass "cursor fetches the version-addressed tarball, not cursor.com/install" ||
  fail "cursor must fetch downloads.cursor.com/lab/\${CURSOR_VERSION}/..."

# hermes: assert the LIMIT is documented, so nobody later reads its lone script
# digest as an artifact pin. The honesty is part of the contract.
grep -q 'NO version-addressed artifact' "$REPO/hermes/bootstrap.sh" &&
  pass "hermes states that no version-addressed artifact exists to pin" ||
  fail "hermes/bootstrap.sh must state that its pin covers the installer SCRIPT only"

# =============================================================================
# 6. EXECUTION TEST — the digest gate actually RUNS and actually REFUSES.
#
# Everything above is a grep, and a grep cannot tell a live gate from a dead one.
# This section extracts the REAL grok install block from the REAL bootstrap.sh and
# runs it twice against a stubbed network, changing exactly ONE variable between
# the arms: whether the pinned digest matches the bytes the network returns.
#
#   arm A (control): digest matches the served bytes -> install MUST happen
#   arm B (defect):  digest does not match           -> install MUST NOT happen
#
# Arm A is what makes arm B meaningful. Without it, arm B would pass just as
# happily if the block were deleted, commented out, or never reached — the exact
# failure mode where a green check measures nothing.
# =============================================================================
STUB="$TMP/stub"
mkdir -p "$STUB"

# The arms run with a DELIBERATELY minimal PATH (so `command -v grok` fails and the
# empty-delta branch is entered), which means the platform's own sha256sum may not
# be reachable from it — on this author's machine it lives in /sbin, and the first
# run of this test consequently exercised the production code's "sha256sum
# unavailable, refuse to install" branch and reported a vacuous pass on arm B. The
# control arm caught that. Shim it into the stub dir UNCONDITIONALLY so both arms
# always have one, resolving the real binary by absolute path (or macOS `shasum`).
REAL_SHA256="$(command -v sha256sum || true)"
if [ -n "$REAL_SHA256" ]; then
  printf '#!/bin/sh\nexec %s "$@"\n' "$REAL_SHA256" > "$STUB/sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  printf '#!/bin/sh\nexec %s -a 256 "$@"\n' "$(command -v shasum)" > "$STUB/sha256sum"
else
  fail "no sha256sum or shasum on this machine — the execution test cannot run"
fi
chmod +x "$STUB/sha256sum" 2>/dev/null || true

# The tampered payload the "network" serves.
printf 'this is not the pinned grok binary\n' > "$TMP/evil"
EVIL_SHA="$("$STUB/sha256sum" "$TMP/evil" | cut -d' ' -f1)"

# curl stub: honours `-o <path>` and serves the payload. Records that it was called.
cat > "$STUB/curl" <<'CURLEOF'
#!/bin/sh
echo "curl called: $*" >> "$STUB_LOG/curl.calls"
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] || exit 1
cat "$STUB_LOG/payload" > "$out"
exit 0
CURLEOF
chmod +x "$STUB/curl"

# install stub: records that the artifact was accepted. Its ABSENCE after arm B is
# the assertion.
cat > "$STUB/install" <<'INSTEOF'
#!/bin/sh
echo "install called: $*" >> "$STUB_LOG/install.calls"
exit 0
INSTEOF
chmod +x "$STUB/install"

# Extract the REAL block from the REAL file — not a copy that can drift out of
# step with what ships. From `GROK_VERSION=` to the closing `fi` at column 0.
awk '/^GROK_VERSION=/ { f = 1 } f { print } f && /^fi$/ { exit }' \
  "$REPO/grok/bootstrap.sh" > "$TMP/block.sh"

# Control on the EXTRACTION itself: an empty or truncated fragment would make both
# arms pass by doing nothing at all.
if [ ! -s "$TMP/block.sh" ] || ! grep -q 'sha256sum -c -' "$TMP/block.sh" ||
   ! grep -q 'install -m 0755' "$TMP/block.sh"; then
  fail "could not extract grok's install block from bootstrap.sh — the execution test is not testing anything"
else
  pass "extracted grok's real install block ($(wc -l < "$TMP/block.sh" | tr -d ' ') lines)"

  run_arm() {
    arm="$1"; expect_sha="$2"
    rm -rf "$TMP/log"; mkdir -p "$TMP/log"
    cp "$TMP/evil" "$TMP/log/payload"
    # Swap ONLY the expected digest. Everything else is the shipped code.
    sed "s/^GROK_SHA256=.*/GROK_SHA256=$expect_sha/" "$TMP/block.sh" > "$TMP/log/arm.sh"
    # A PATH with no `grok` on it, so `command -v grok` fails and the block is
    # entered — the empty-delta condition this defect lives in.
    STUB_LOG="$TMP/log" PATH="$STUB:/usr/bin:/bin" \
      sh "$TMP/log/arm.sh" > "$TMP/log/out" 2> "$TMP/log/err"
  }

  # --- arm A: digest matches the served bytes -------------------------------
  run_arm A "$EVIL_SHA"
  if [ -f "$TMP/log/curl.calls" ] && [ -f "$TMP/log/install.calls" ]; then
    pass "control arm: matching digest -> artifact fetched AND installed (the block is live)"
  else
    fail "control arm: matching digest did NOT install — the block never ran, so the defect arm below proves nothing (curl=$([ -f "$TMP/log/curl.calls" ] && echo yes || echo no) install=$([ -f "$TMP/log/install.calls" ] && echo yes || echo no))"
  fi

  # --- arm B: digest does not match -----------------------------------------
  run_arm B 0000000000000000000000000000000000000000000000000000000000000000
  if [ ! -f "$TMP/log/curl.calls" ]; then
    fail "defect arm: the fetch never happened — this arm is vacuous"
  elif [ -f "$TMP/log/install.calls" ]; then
    fail "defect arm: TAMPERED artifact was INSTALLED — the digest gate does not gate (#2948)"
  elif ! grep -q 'DIGEST MISMATCH' "$TMP/log/err"; then
    fail "defect arm: tampered artifact refused, but silently — the operator must be told"
  else
    pass "defect arm: tampered artifact fetched, digest rejected, NOT installed, reported loudly"
  fi
fi

# =============================================================================
# 7. #2943 — every skill that pulls attacker-controllable text into the agent's
#    context carries an untrusted-data instruction, in GREPPABLE form.
#
# The instruction was already present in all three; the issue's own grep
# (`inject|untrusted|treat .* as data`) missed zipbox-websearch's because it read
# "hostile data" and the search wanted "untrusted". A test beats a vocabulary
# convention: this asserts the PROPERTY, and the wording was aligned so the
# property is findable by the obvious search.
# =============================================================================
web_skills='zipbox-browser zipbox-email zipbox-websearch'
checked=0
fails_before=$fails
for s in $web_skills; do
  f="$REPO/skills/$s/SKILL.md"
  if [ ! -f "$f" ]; then
    fail "skills/$s/SKILL.md is missing — this scan is broken, not the skill set"
    continue
  fi
  checked=$((checked + 1))
  grep -qi 'untrusted' "$f" ||
    fail "skills/$s/SKILL.md pulls in attacker-controllable text but carries no 'untrusted' instruction (#2943)"
done
[ "$checked" -eq 3 ] || fail "expected 3 web-text skills, checked $checked"
[ "$fails" -eq "$fails_before" ] && pass "all 3 web-text skills carry a greppable untrusted-data instruction"

if [ "$fails" -gt 0 ]; then
  printf '\n%s test(s) failed\n' "$fails" >&2
  exit 1
fi
printf '\nall runtime supply-chain tests passed\n'
