#!/bin/sh
# cline/launch.sh must suppress the ClinePass upsell before it execs cline.
#
# WHY THIS IS A CONTRACT AND NOT A PREFERENCE (#2924). cline 3.0.46 paints a
# "Try ClinePass" subscription modal on startup that is modal over the KEYBOARD:
# it binds Enter to "open the promo URL". A user types their first prompt, presses
# Enter, and the Enter is consumed by the modal. The prompt is never submitted —
# no turn, no error shown, no billed generation — while the composer still holds
# the text, so the session looks alive and simply never answers.
#
# Measured on proof-run-02 (gohan) through a REAL agent-shell launch at harness
# ref 559ef061, one variable per run:
#   no env var, no Esc    -> modal shown, Enter eaten, NO billing transaction
#   no env var, Esc first -> modal dismissed, turn ran, -617 uUSD
#   env var, no Esc       -> modal absent (0 occurrences), turn ran, -617 uUSD
#
# The regression this guards is a DELETION, and a deletion is exactly what a
# tidy-up pass does to a line whose purpose is invisible from the code. Losing it
# restores a silent first-prompt failure that no other vantage reports.
set -u

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LAUNCHER="$REPO/cline/launch.sh"

# cline's own opt-out. The CLI binary carries CLINE_FORCE_CLINE_PASS_NOTICE beside
# it, which is what makes this the vendor switch rather than a guess.
ENV_VAR='CLINE_DISABLE_CLINE_PASS_NOTICE'
EXPORT_LINE='export CLINE_DISABLE_CLINE_PASS_NOTICE=1'
EXEC_LINE='exec cline'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fails=0
checks=0

pass() {
  checks=$((checks + 1))
  printf 'ok   - %s\n' "$1"
}

fail() {
  checks=$((checks + 1))
  printf 'FAIL - %s\n' "$1" >&2
  fails=$((fails + 1))
}

# Is the notice suppressed, and suppressed EARLY ENOUGH to matter? An export that
# lands after `exec cline` never runs, so line order is the whole point: assert the
# export exists AND precedes the exec.
suppresses_notice() {
  file="$1"
  grep -Fq -- "$EXPORT_LINE" "$file" || return 1
  export_at="$(grep -Fn -- "$EXPORT_LINE" "$file" | head -1 | cut -d: -f1)"
  exec_at="$(grep -Fn -- "$EXEC_LINE" "$file" | head -1 | cut -d: -f1)"
  [ -n "$export_at" ] && [ -n "$exec_at" ] || return 1
  [ "$export_at" -lt "$exec_at" ] || return 1
  return 0
}

# --- the contract ------------------------------------------------------------
if [ ! -f "$LAUNCHER" ]; then
  fail "cline/launch.sh exists"
else
  pass "cline/launch.sh exists"

  if suppresses_notice "$LAUNCHER"; then
    pass "cline/launch.sh exports $ENV_VAR before exec cline"
  else
    fail "cline/launch.sh exports $ENV_VAR before exec cline"
  fi

  # The suppression must be UNCONDITIONAL. Gating it on the platform-funded guard
  # ($TRIBES_LLM_MODEL / $token) would leave every BYO box with the upsell still
  # eating the first Enter — the bug is a stolen keystroke, which has nothing to do
  # with who funds the tokens.
  guarded="$(awk -v want="$EXPORT_LINE" '
    index($0, want) { print depth; exit }
    /^[[:space:]]*(if|for|while|case)[[:space:]]/ { depth++ }
    /^[[:space:]]*(fi|done|esac)[[:space:]]*$/    { if (depth > 0) depth-- }
  ' "$LAUNCHER")"
  if [ "${guarded:-1}" = "0" ]; then
    pass "the suppression is unconditional (runs on BYO boxes too)"
  else
    fail "the suppression is unconditional (runs on BYO boxes too)"
  fi
fi

# --- positive controls -------------------------------------------------------
# A checker that can never fire would pass this file forever. Rebuild each defect
# and require the detector to catch it.
MISSING="$TMP/missing-launch.sh"
{
  printf '#!/bin/sh\n'
  printf 'token="${OPENROUTER_API_KEY:-}"\n'
  printf '%s -i --auto-approve true\n' "$EXEC_LINE"
} > "$MISSING"
if suppresses_notice "$MISSING"; then
  fail "detector flags a launcher missing the suppression"
else
  pass "detector flags a launcher missing the suppression"
fi

TOO_LATE="$TMP/too-late-launch.sh"
{
  printf '#!/bin/sh\n'
  printf '%s -i --auto-approve true\n' "$EXEC_LINE"
  printf '%s\n' "$EXPORT_LINE"
} > "$TOO_LATE"
if suppresses_notice "$TOO_LATE"; then
  fail "detector flags a suppression placed after exec (dead code)"
else
  pass "detector flags a suppression placed after exec (dead code)"
fi

GOOD="$TMP/good-launch.sh"
{
  printf '#!/bin/sh\n'
  printf '%s\n' "$EXPORT_LINE"
  printf '%s -i --auto-approve true\n' "$EXEC_LINE"
} > "$GOOD"
if suppresses_notice "$GOOD"; then
  pass "detector accepts a correctly-ordered launcher"
else
  fail "detector accepts a correctly-ordered launcher"
fi

# A sweep that examined nothing would report all-clear — an early `exit`, a bad
# path, a renamed directory. Assert the population BEFORE this check runs: the six
# above are the whole suite, and this line is the seventh.
if [ "$checks" -eq 6 ]; then
  pass "ran all 6 preceding checks"
else
  fail "ran all 6 preceding checks (saw $checks)"
fi

if [ "$fails" -ne 0 ]; then
  printf '\n%s check(s) failed\n' "$fails"
  exit 1
fi
printf '\nall cline notice suppression checks passed\n'
