#!/bin/sh
# claude harness — launch (runs EVERY launch, as root, cwd /root/workspace, under sh).
# Exports the ENV-based proxy config for the auto-launched harness process, then
# refreshes the SAME live token into settings.json's "env" block so a manually
# typed `claude` in the exit shell — a separate process that never sees these
# exports, which die with this process once we exec — is authenticated too.
# Config paths are $HOME-relative — the dispatcher decides HOME (old: workspace,
# new: /root).

# --- re-render the agent primer (restore-safety, same as the token below) ---
# bootstrap.sh's sed CONSUMED the primer placeholders, freezing whatever the box
# knew at first boot: the boot-slug hostname (a claim adds a DNS alias and never
# renames the VM) and "none" identity values if the agent_identities row wasn't
# bound yet. AGENTS.md is auto-loaded into the agent's context, so a frozen primer
# feeds it a WRONG public URL by default. Re-render from the untouched template
# with this launch's live env so both self-heal and survive restore.
if [ -e /opt/tribes/render-primer.sh ]; then
  TRIBES_PRIMER_ALSO_CLAUDE_MD=1 sh /opt/tribes/render-primer.sh ||
    echo "[primer] render-primer.sh FAILED — primer may be stale" >&2
else
  # Loud on purpose: `2>/dev/null || true` here once turned "my dependency was
  # never installed" into silence, and the primer fix sat INERT on every box
  # through review, a Fable pass and four ref moves. A missing renderer means the
  # harness install fetched the wrong ref — say so.
  echo "[primer] /opt/tribes/render-primer.sh MISSING — primer NOT refreshed (harness install incomplete / wrong ref?)" >&2
fi

# --- platform-funded: point claude at the metered LLM proxy --------------------
# When the control plane marks claude platform-funded it injects TRIBES_LLM_MODEL +
# OPENROUTER_API_KEY; the provider placeholder is supplied in-VM by the platform-provided OpenRouter placeholder (a
# short provider placeholder signed with the P-256 agent key). Point claude's Anthropic
# Messages surface at `https://openrouter.ai/api`; ANTHROPIC_AUTH_TOKEN is sent as
# the Authorization: Placeholder header. If the proxy env is absent or the box is
# keyless (BYO/external — no available placeholder) we skip and claude falls back to
# whatever creds the user supplies. Kept even though settings.json's env block
# (below) covers the same values: it's what actually authenticates the launched
# harness if the on-disk config was ever left mid-edit (bootstrap fill failure) or
# a BYO box flips to platform-funded on a restore (bootstrap already ran once and
# won't re-seed the placeholders).
# Read the placeholder once; both the env export and the on-disk refresh below use it.
token="${OPENROUTER_API_KEY:-}"
if [ -n "$TRIBES_LLM_MODEL" ] && [ -n "$token" ]; then
  proxy="https://openrouter.ai/api"
  export ANTHROPIC_BASE_URL="$proxy"
  export ANTHROPIC_AUTH_TOKEN="$token"
  # Map each /model tier to a real proxy model (all three allow-listed) so
  # Opus/Sonnet/Haiku are genuine choices, not three aliases of one model. The
  # session default stays the configured model ($TRIBES_LLM_MODEL) to keep cost
  # predictable until the user picks Opus.
  export ANTHROPIC_MODEL="$TRIBES_LLM_MODEL"
  export ANTHROPIC_DEFAULT_OPUS_MODEL="anthropic/claude-opus-4.8"
  export ANTHROPIC_DEFAULT_SONNET_MODEL="anthropic/claude-sonnet-4.6"
  export ANTHROPIC_DEFAULT_HAIKU_MODEL="anthropic/claude-haiku-4.5"
fi

# --- restore-safety: refresh the on-disk token (manual/exit-shell auth) ----
# The placeholder is a provider placeholder supplied per launch, so the token baked into
# settings.json at bootstrap goes stale. Re-point it at the freshly-supplied key on
# every launch — same idiom as the other file-based harnesses (see CONTRACT.md).
# Match the ANTHROPIC_AUTH_TOKEN field value so the swap works for any prior token
# (a placeholder carries no sed-special chars). No-op on a cold boot (bootstrap just wrote
# this same value); skipped on BYO/unset (bootstrap.sh already stripped the env block).
CFG="$HOME/.claude/settings.json"
if [ -n "$token" ] && [ -f "$CFG" ]; then
  sed -i "s|\"ANTHROPIC_AUTH_TOKEN\": \"[^\"]*\"|\"ANTHROPIC_AUTH_TOKEN\": \"$token\"|" "$CFG"
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

# IS_SANDBOX=1 lets --dangerously-skip-permissions run as root.
if [ -n "${ZIPBOX_EGRESS_PROXY_URL:-}" ]; then
  export HTTPS_PROXY="$ZIPBOX_EGRESS_PROXY_URL"
  export HTTP_PROXY="$ZIPBOX_EGRESS_PROXY_URL"
fi

exec env IS_SANDBOX=1 claude --dangerously-skip-permissions
