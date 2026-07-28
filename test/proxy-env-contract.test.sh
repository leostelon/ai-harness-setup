#!/bin/sh
# Every launcher that exports a blanket HTTP_PROXY/HTTPS_PROXY must not also carry
# the comment claiming it does not.
#
# The comment was TRUE when written: the forwarder's CONNECT handling was an exact
# catalog allowlist, so a blanket proxy really would have 403'd github/npm/apt/pypi.
# terminal#2883 (default-allow with a resolved-address deny floor), #2887 (plain-HTTP
# absolute-URI) and #2891 (bracketed IPv6 literals) replaced that allowlist with a
# passthrough floor, so the claim stopped being true — but every copy of the comment
# stayed, sitting directly above the code that contradicts it (terminal#2875).
#
# A stale comment is not cosmetic here. This one names a specific failure mode
# ("would break github/npm/apt/pypi on every box") and would talk the next reader out
# of the correct fix. The whole point of terminal#2875 was that the two readings imply
# opposite fixes.
#
# So this is a mechanism, not a reminder: re-adding the claim while the export is
# present fails CI. The check is deliberately narrow — it asserts the two are never
# BOTH present in one launcher. It takes no position on whether the export should be
# process-wide (a live design question against EgressProxyConfig.ts's "the guest routes
# through it only when IT chooses"); it only forbids the file from asserting one thing
# and doing the other.
set -u

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
HARNESSES='pi claude codex grok hermes openclaw opencode cline cursor'

# The claim and the code, each matched as a fixed string.
CLAIM='We do NOT set HTTP_PROXY/HTTPS_PROXY'
EXPORT_LINE='export HTTPS_PROXY="$ZIPBOX_EGRESS_PROXY_URL"'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fails=0

pass() {
  printf 'ok   - %s\n' "$1"
}

fail() {
  printf 'FAIL - %s\n' "$1" >&2
  fails=$((fails + 1))
}

# Does one launcher assert the claim while shipping the export?
contradicts() {
  file="$1"
  grep -Fq -- "$CLAIM" "$file" || return 1
  grep -Fq -- "$EXPORT_LINE" "$file" || return 1
  return 0
}

# --- the contract ------------------------------------------------------------
checked=0
for harness in $HARNESSES; do
  launcher="$REPO/$harness/launch.sh"
  if [ ! -f "$launcher" ]; then
    fail "$harness/launch.sh exists"
    continue
  fi
  checked=$((checked + 1))
  if contradicts "$launcher"; then
    fail "$harness/launch.sh does not claim it skips HTTP_PROXY while exporting it"
  else
    pass "$harness/launch.sh does not claim it skips HTTP_PROXY while exporting it"
  fi
done

# A vacuous sweep — a bad glob, a renamed directory — would report all-clear having
# examined nothing. Assert the population it actually walked.
expected=0
for harness in $HARNESSES; do
  expected=$((expected + 1))
done
if [ "$checked" -eq "$expected" ]; then
  pass "examined all $expected launchers"
else
  fail "examined all $expected launchers (saw $checked)"
fi

# --- positive control --------------------------------------------------------
# A checker that can never fire would pass this file forever. Re-introduce the exact
# defect into a copy and require the detector to catch it; then confirm a launcher
# carrying ONLY the export (claude's shape) is not flagged, so the check keys on the
# contradiction rather than on the export alone.
MUTANT="$TMP/mutant-launch.sh"
{
  printf '#!/bin/sh\n'
  printf '# %s: the forwarder catalog is a CONNECT allowlist.\n' "$CLAIM"
  printf 'if [ -n "${ZIPBOX_EGRESS_PROXY_URL:-}" ]; then\n'
  printf '  %s\n' "$EXPORT_LINE"
  printf 'fi\n'
} > "$MUTANT"
if contradicts "$MUTANT"; then
  pass "detector flags a launcher that re-introduces the claim"
else
  fail "detector flags a launcher that re-introduces the claim"
fi

EXPORT_ONLY="$TMP/export-only-launch.sh"
{
  printf '#!/bin/sh\n'
  printf 'if [ -n "${ZIPBOX_EGRESS_PROXY_URL:-}" ]; then\n'
  printf '  %s\n' "$EXPORT_LINE"
  printf 'fi\n'
} > "$EXPORT_ONLY"
if contradicts "$EXPORT_ONLY"; then
  fail "detector ignores a launcher that exports without the claim"
else
  pass "detector ignores a launcher that exports without the claim"
fi

CLAIM_ONLY="$TMP/claim-only-launch.sh"
{
  printf '#!/bin/sh\n'
  printf '# %s: this launcher genuinely does not.\n' "$CLAIM"
} > "$CLAIM_ONLY"
if contradicts "$CLAIM_ONLY"; then
  fail "detector ignores a launcher that claims without exporting"
else
  pass "detector ignores a launcher that claims without exporting"
fi

if [ "$fails" -ne 0 ]; then
  printf '\n%s check(s) failed\n' "$fails"
  exit 1
fi
printf '\nall proxy env contract checks passed\n'
