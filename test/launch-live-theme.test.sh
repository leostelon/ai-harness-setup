#!/bin/sh
# Every launcher that themes its harness must read the LIVE theme, not only the
# create-time one.
#
# TRIBES_THEME is fixed when the sandbox is CREATED and never changes again, so a
# launcher that reads only that variable pins its harness to whatever the browser
# happened to be showing at create time — for the life of the box. The in-VM
# bridge writes the current theme to /run/tribes-theme on every browser attach and
# every theme frame, so preferring that file (with TRIBES_THEME as the fallback
# for a box no browser has touched yet) is what makes a light/dark toggle actually
# take effect on the next launch.
#
# grok has always done this. hermes did not, which is why its skin was frozen.
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

# Launchers that theme their harness at all. A launcher NOT in this list is one
# whose harness reads the terminal directly (OSC 10/11 or DEC 2031) and needs no
# file; adding one here without wiring the file is what this test catches.
THEMING_LAUNCHERS="grok hermes"

# Both launchers DOCUMENT this behaviour in comments that name both TRIBES_THEME
# and /run/tribes-theme, so a line-order check over the raw file measures where
# the comments sit, not where the code does — it failed grok, which has always
# been correct. Compare CODE lines only.
code_only() {
  sed 's/[[:space:]]*#.*$//' "$1"
}

for harness in $THEMING_LAUNCHERS; do
  launch="$REPO/$harness/launch.sh"

  if ! grep -q 'TRIBES_THEME' "$launch"; then
    fail "$harness/launch.sh no longer themes anything — remove it from this list or restore the theming"
    continue
  fi

  if grep -q '/run/tribes-theme' "$launch"; then
    pass "$harness/launch.sh reads the live theme"
  else
    fail "$harness/launch.sh reads only the create-time TRIBES_THEME — a browser theme toggle can never reach it"
  fi

  # Order matters, not just presence: the live file has to be consulted BEFORE the
  # create-time fallback, or the frozen value wins anyway.
  live_line="$(code_only "$launch" | grep -n '/run/tribes-theme' | head -n 1 | cut -d: -f1)"
  env_line="$(code_only "$launch" | grep -n 'TRIBES_THEME' | head -n 1 | cut -d: -f1)"
  if [ -n "$live_line" ] && [ -n "$env_line" ] && [ "$live_line" -lt "$env_line" ]; then
    pass "$harness/launch.sh prefers the live theme over the create-time fallback"
  else
    fail "$harness/launch.sh consults TRIBES_THEME before /run/tribes-theme"
  fi
done

if [ "$failures" -gt 0 ]; then
  printf '\n%s check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall live-theme checks passed\n'
