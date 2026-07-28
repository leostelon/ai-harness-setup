#!/bin/sh
# cursor harness — launch (runs on EVERY launch, as root, cwd /root/workspace, under sh).
# Cursor cannot be pointed at the metered LLM proxy (no base-URL override), so
# auth is the user's OWN Cursor account: `/login` in the TUI, or CURSOR_API_KEY
# if the env carries one — we pass the inherited env through untouched. No
# tribes token lives in any file, so there is no per-launch token refresh.

# No browser exists in the VM — make `agent login` PRINT its auth URL instead
# of trying to open one, so the user completes OAuth on their own machine.
# --- re-render the agent primer (restore-safety, like the token refresh) -----
# bootstrap.sh's sed CONSUMED the primer placeholders, freezing whatever the box
# knew at first boot: the boot-slug hostname (a claim adds a DNS alias and never
# renames the VM) and "none" identity values if the agent_identities row wasn't
# bound yet. AGENTS.md is auto-loaded into the agent's context, so a frozen primer
# feeds it a WRONG public URL by default. Re-render from the untouched template
# with this launch's live env so both self-heal and survive restore.

# --- terminal colour scheme for THIS launch ---------------------------------
# Re-derived on EVERY launch so a mid-session light/dark toggle takes effect the
# next time the harness starts. Prefer the LIVE theme the in-VM bridge writes to
# /run/tribes-theme on every browser theme frame; fall back to the create-time
# TRIBES_THEME for a box no browser has touched yet.
#
# COLORFGBG is the de-facto standard variable a terminal application reads to
# decide whether its background is light or dark WITHOUT an OSC round trip
# ('<fg>;<bg>'; the BACKGROUND field is what callers test -- 0-6 and 8 are dark,
# 7 and 9-15 light). Unset is NOT neutral: a tool that consults it finds nothing
# and falls back to its OWN default, almost always dark, so a light-theme user
# got dark-themed tools inside a correctly-recoloured terminal. Exported here
# rather than probed, because an OSC-11 probe before exec wedged grok's pager.
#
# TRIBES_THEME is re-exported from the same live value so anything reading it
# later in this launch sees the current theme, not the create-time snapshot.
theme="$(cat /run/tribes-theme 2>/dev/null)"
[ "$theme" = light ] || [ "$theme" = dark ] || theme=$([ "$TRIBES_THEME" = light ] && echo light || echo dark)
export TRIBES_THEME="$theme"
# Multi-line on purpose: a single-line `if ...; fi` increments the nesting depth
# of line-scanning checks (test/cline-notice-suppression.test.sh counts `if` at
# line start against a bare `fi`) and would make every later line look guarded.
if [ "$theme" = light ]; then
  export COLORFGBG='0;15'
else
  export COLORFGBG='15;0'
fi

if [ -e /opt/tribes/render-primer.sh ]; then
  sh /opt/tribes/render-primer.sh ||
    echo "[primer] render-primer.sh FAILED — primer may be stale" >&2
else
  # Loud on purpose: `2>/dev/null || true` here once turned "my dependency was
  # never installed" into silence, and the primer fix sat INERT on every box
  # through review, a Fable pass and four ref moves. A missing renderer means the
  # harness install fetched the wrong ref — say so.
  echo "[primer] /opt/tribes/render-primer.sh MISSING — primer NOT refreshed (harness install incomplete / wrong ref?)" >&2
fi

export NO_OPEN_BROWSER=1

# bootstrap.sh symlinked the binary to /usr/local/bin; keep the installer's own
# bin dir (pinned to /root/workspace at install time, regardless of the
# dispatcher's HOME) on PATH too as a fallback.
export PATH="/root/workspace/.local/bin:$PATH"

# --- shared agent skills: reconverge on every launch -------------------------
# Drive-first (#1914): run the installer baked onto the shared read-only
# /opt/harnesses drive, so every launch reconverges /root/skills on the drive's
# pinned catalog with no network. The fetch survives as the fallback for a
# drive that predates skills (old image, dev backend) and for a pinned
# TRIBES_HARNESS_REF (QA), which must exercise that branch's own installer.
# Tolerant + tight timeout; a slow or failed fetch leaves the launch (and any
# prior install) unaffected.
if [ -z "${TRIBES_HARNESS_REF:-}" ] && [ -f /opt/harnesses/skills/install-skills.sh ]; then
  sh /opt/harnesses/skills/install-skills.sh || true
else
  SKILLS_RAW_BASE="$(echo "${TRIBES_HARNESS_REPO:-https://github.com/tribes-protocol/ai-harness-setup}" | sed 's#//github\.com#//raw.githubusercontent.com#')"
  # NEVER `| sh`, and NEVER a mutable ref (#2948 / #2937). Same contract as
  # bootstrap.sh: resolve guest pin -> host pin -> the last reviewed release (never
  # `main`, which routes around the release pin), download to a file, require the
  # complete file, then run it. A truncated transfer can no longer half-execute.
  SKILLS_REF="${TRIBES_HARNESS_REF:-${HOST_HARNESS_REF:-68adbaccc020d97b8b62a6f400c8283b22ecae07}}"
  sk="$(mktemp 2>/dev/null || echo /tmp/install-skills.$$)"
  if curl -fsSL --max-time 10 "$SKILLS_RAW_BASE/$SKILLS_REF/install-skills.sh" -o "$sk" 2>/dev/null &&
     [ -s "$sk" ] && [ "$(tail -n 1 "$sk")" = "exit 0" ]; then
    sh "$sk" || true
  else
    echo "[skills] installer fetch failed or INCOMPLETE at ref '$SKILLS_REF' — skills NOT installed" >&2
  fi
  rm -f "$sk"
fi

exec cursor
