#!/bin/sh
# EVERY launcher must export COLORFGBG, derived from the LIVE theme.
#
# COLORFGBG is the de-facto standard variable a terminal application reads to
# decide whether its background is light or dark without an OSC round trip. It
# was previously set NOWHERE in the guest — not by the control plane, not by the
# dispatcher, not by any launcher. An unset value is not neutral: a tool that
# consults it finds nothing and falls back to its OWN default, almost always
# dark. So a user on a light theme got a correctly-recoloured xterm containing
# individually dark-themed tools, and the surface looking right is exactly why it
# went unnoticed.
#
# This is DELIBERATELY every launcher, not just the theming ones in
# launch-live-theme.test.sh. That test covers harnesses that cannot detect the
# terminal themselves (grok, hermes) and therefore need the file to configure
# their OWN skin. COLORFGBG is a different concern: the harness process and
# EVERYTHING IT SPAWNS inherit it, so a harness that detects its own theme
# perfectly well still needs to hand a correct value to the tools it runs.
#
# The value must come from /run/tribes-theme (live, rewritten by the in-VM bridge
# on every browser theme frame) and not from TRIBES_THEME alone, which is frozen
# at sandbox create time.
set -eu

REPO="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
failures=0

pass() {
  printf 'PASS %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1" >&2
  failures=$((failures + 1))
}

# Every harness that has a launcher. A new harness directory with a launch.sh
# must appear here — an unlisted launcher is an unthemed harness.
ALL_LAUNCHERS="claude cline codex cursor grok hermes openclaw opencode pi"

# Strip comments before matching: both the block and the surrounding prose name
# COLORFGBG and /run/tribes-theme, so a raw grep would pass on documentation
# alone. Measure the CODE.
code_only() {
  sed 's/[[:space:]]*#.*$//' "$1"
}

for harness in $ALL_LAUNCHERS; do
  launch="$REPO/$harness/launch.sh"

  if [ ! -e "$launch" ]; then
    fail "$harness/launch.sh is missing — remove it from ALL_LAUNCHERS or restore the file"
    continue
  fi

  if ! code_only "$launch" | grep -q 'export COLORFGBG'; then
    fail "$harness/launch.sh does not export COLORFGBG — its harness's tools will guess the theme"
    continue
  fi

  if ! code_only "$launch" | grep -q '/run/tribes-theme'; then
    fail "$harness/launch.sh sets COLORFGBG but not from the live /run/tribes-theme"
    continue
  fi

  # Both polarities must be present, and they must differ in the BACKGROUND
  # field. A launcher that exported the same value for both would satisfy a
  # naive "does it mention COLORFGBG" check while telling every consumer the
  # same thing — which is the original bug wearing a fix's clothes.
  if ! code_only "$launch" | grep -q "COLORFGBG='0;15'"; then
    fail "$harness/launch.sh has no light-background COLORFGBG ('0;15')"
    continue
  fi

  if ! code_only "$launch" | grep -q "COLORFGBG='15;0'"; then
    fail "$harness/launch.sh has no dark-background COLORFGBG ('15;0')"
    continue
  fi

  pass "$harness/launch.sh exports COLORFGBG from the live theme, both polarities"
done

# Behavioural check of the shared resolution, run in a real POSIX shell rather
# than asserted from source: the live file must WIN over the create-time seed,
# and an absent or malformed file must fall back instead of crashing.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

resolve() {
  # $1 = file contents ('' means no file at all), $2 = TRIBES_THEME seed
  if [ -n "$1" ]; then
    printf '%s\n' "$1" > "$tmp/theme"
  else
    rm -f "$tmp/theme"
  fi
  TRIBES_THEME="$2" sh -c '
    theme="$(cat "$1" 2>/dev/null)"
    [ "$theme" = light ] || [ "$theme" = dark ] || theme=$([ "$TRIBES_THEME" = light ] && echo light || echo dark)
    if [ "$theme" = light ]; then printf "0;15"; else printf "15;0"; fi
  ' _ "$tmp/theme"
}

check() {
  # $1 = description, $2 = expected, $3 = file contents, $4 = seed
  got="$(resolve "$3" "$4")"
  if [ "$got" = "$2" ]; then
    pass "resolution: $1"
  else
    fail "resolution: $1 — expected $2, got $got"
  fi
}

check "live light file beats a dark create-time seed" '0;15' 'light' 'dark'
check "live dark file beats a light create-time seed" '15;0' 'dark' 'light'
check "absent file falls back to the light seed" '0;15' '' 'light'
check "absent file falls back to the dark seed" '15;0' '' 'dark'
check "malformed file falls back to the seed" '0;15' 'banana' 'light'
check "nothing at all defaults to dark" '15;0' '' ''

if [ "$failures" -ne 0 ]; then
  printf '\n%s check(s) failed\n' "$failures" >&2
  exit 1
fi

printf '\nall COLORFGBG checks passed\n'
