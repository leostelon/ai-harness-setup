#!/bin/sh
# opencode harness launch — runs on EVERY launch, as root, cwd /root/workspace, sh.
# opencode config is entirely FILE-based (opencode.json, written by bootstrap.sh)
# — there is no env-based config, and theme:"system" makes the TUI follow the
# terminal, so there is no per-launch theme rewrite and nothing to export here.

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

# --- restore-safety: refresh the proxy token from the LIVE env --------------
# The placeholder is a provider placeholder supplied in-VM by the platform-provided OpenRouter placeholder (signed
# with the P-256 agent key). bootstrap.sh baked one into opencode.json (apiKey) on
# first boot; it goes stale (expiry, or a PAUSE -> RESTORE onto a disk holding the
# previous boot's token), so refresh and re-point the on-disk apiKey every launch.
# Match the apiKey field value so the swap works for any prior token (a placeholder has no
# sed-special chars). No-op on a cold boot; skipped on a keyless BYO/unset box
# (file removed, or no available key). Config paths are $HOME-relative — the
# dispatcher decides HOME (old: workspace, new: /root).
CFG="$HOME/.config/opencode/opencode.json"
token="${OPENROUTER_API_KEY:-}"
if [ -n "$token" ] && [ -f "$CFG" ]; then
  sed -i "s|\"apiKey\": \"[^\"]*\"|\"apiKey\": \"$token\"|" "$CFG"
fi

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

# --- close the direct-provider escape hatch (#2255) --------------------------
# On a platform-funded box the control plane injects a PLACEHOLDER OPENROUTER_API_KEY
# (SandboxBootEnv.ts) intended for an egress injector that swaps in the real key.
# On zipbox no such injector is on this path, so the placeholder is just a stray
# credential-shaped env var: harnesses that auto-register a provider on env
# presence alone (pi, opencode) can pick OpenRouter DIRECTLY and 401 against
# openrouter.ai instead of using the metered proxy. Dropping it before exec leaves
# the metered proxy as the only route the harness can see.
#
# We DO set HTTP_PROXY/HTTPS_PROXY, just before the exec below. This once said the
# opposite, and it was true when written: the forwarder's CONNECT handling was an
# exact catalog allowlist that 403'd every non-catalog authority, so a blanket proxy
# really would have broken github/npm/apt/pypi. terminal#2883 replaced that with
# default-allow passthrough over a resolved-address deny floor (#2887 added plain-HTTP
# absolute-URI, #2891 brought bracketed IPv6 literals to the same floor), so a
# non-catalog host now tunnels straight through unmetered. Catalog hosts stay metered
# on :443. The claim outlived the behaviour it described and sat directly above the
# code contradicting it (terminal#2875); test/proxy-env-contract.test.sh now fails CI
# if it comes back.
#
# The unset is deliberately guard-scoped, NOT value-scoped (i.e. not "unset only
# if it looks like the placeholder"). Value-matching would couple this script to a
# literal defined in another repo's catalog — a silent no-op the day that value
# changes — and, worse, it would PRESERVE a real OpenRouter key that reached a
# platform-funded box some other way, which is exactly the unmetered bypass this
# closes. byoKey is the supported way to bring your own key, and it is suppressed
# by the guard below.
#
# The guard is the by-construction one: SandboxBootEnv writes TRIBES_LLM_MODEL
# ONLY for proxy-mode, non-byoKey, non-'external' boxes, so BYO/external boxes
# never enter this branch and keep their own OPENROUTER_API_KEY untouched. This is
# structural, not a special case — do not add a byoKey conditional here.
# --- platform-funded but NO credential: fail LOUD, don't boot silently broken ----
# The proxy guard above skips config when the platform key is empty — correct for a
# BYO box (all three env vars unset). But a box the control plane marked
# platform-funded (TRIBES_LLM_MODEL + OPENROUTER_API_KEY present) that arrives with an
# EMPTY $token (the platform-provided OpenRouter placeholder supplied nothing) is a FAILED provider-key delivery, not BYO: it boots, every LLM
# call 401s (totalTokens:0), and every other vantage reads green. Surface it — a
# loud boot-log line AND a health marker the fleet can poll — so "booted with no
# proxy auth" is no longer silent. Cleared on any healthy/BYO boot so the marker
# is a LIVE signal (self-heals on a restore that refreshs the key). (#2472)
if [ -n "$TRIBES_LLM_MODEL" ] && [ -z "$token" ]; then
  echo "[llm-egress] metered egress has no OpenRouter placeholder; every platform-funded LLM call would fail closed." >&2
  mkdir -p /opt/tribes 2>/dev/null || true
  : > /opt/tribes/.llm-egress-key-missing 2>/dev/null || true
else
  rm -f /opt/tribes/.llm-egress-key-missing 2>/dev/null || true
fi

if [ -n "${ZIPBOX_EGRESS_PROXY_URL:-}" ]; then
  export HTTPS_PROXY="$ZIPBOX_EGRESS_PROXY_URL"
  export HTTP_PROXY="$ZIPBOX_EGRESS_PROXY_URL"
fi

exec opencode
