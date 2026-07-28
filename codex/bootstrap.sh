#!/bin/sh
# Codex harness bootstrap — runs ONCE on first boot, as root, cwd /root/workspace, sh.
# Installs the Codex CLI and fills the committed seed config (.codex/config.toml)
# with the runtime proxy + model. Env-based config (OPENAI_API_KEY) is set in
# launch.sh, because exports from this process are lost before the harness launches.
# Config paths are $HOME-relative — the dispatcher decides HOME (old: workspace,
# new: /root).
set -e

# --- install ----------------------------------------------------------------
command -v codex >/dev/null 2>&1 ||
  npm install -g --no-fund --no-audit @openai/codex@latest

# --- seed the shared agent primer -------------------------------------------
# Seed the shared agent primer from the repo root (single source of truth).
RAW_BASE="$(echo "${TRIBES_HARNESS_REPO:-https://github.com/tribes-protocol/ai-harness-setup}" | sed 's#//github\.com#//raw.githubusercontent.com#')"
REF="${TRIBES_HARNESS_REF:-${HOST_HARNESS_REF:-main}}"
# Cache the PLACEHOLDER-BEARING primer + the renderer outside the workspace, then
# render. Bootstrap runs ONCE and its sed consumes the placeholders, so stamping
# them here alone froze the wrong values for the life of the disk: the guest's
# hostname is the boot slug (a claim never renames the VM), and a box bootstrapped
# before its identity row is bound has no TRIBES_IDENTITY_* and froze "none".
# launch.sh re-runs the renderer every launch so both self-heal.
# DRIVE-FIRST, same gate the skills install below uses. The shared read-only
# /opt/harnesses drive bakes the WHOLE template tree at the pinned ref
# (dockers/Dockerfile.harnesses in tribes-protocol/terminal), so a stock boot
# copies the primer + renderer off the drive and touches no network. The curl
# runs only when the drive predates templates (old image, dev backend) or when a
# pinned TRIBES_HARNESS_REF (QA) must exercise that ref's own primer.
#
# Behaviour change, intended: a stock box now gets the PINNED primer instead of
# whatever is on `main`. TRIBES_HARNESS_REF is unset in this env on stock boxes,
# so the curl below was resolving REF to `main` while the template itself was
# pinned — the primer floated. A hotfix pushed to `main` now needs a pin bump +
# drive rebake to reach stock boxes.
mkdir -p /opt/tribes 2>/dev/null || true
if [ -z "${TRIBES_HARNESS_REF:-}" ] && [ -f /opt/harnesses/templates/render-primer.sh ]; then
  cp /opt/harnesses/templates/AGENTS.md /opt/tribes/AGENTS.md.tmpl 2>/dev/null || true
  cp /opt/harnesses/templates/render-primer.sh /opt/tribes/render-primer.sh 2>/dev/null || true
else
  curl -fsSL "$RAW_BASE/$REF/AGENTS.md" -o /opt/tribes/AGENTS.md.tmpl 2>/dev/null || true
  curl -fsSL "$RAW_BASE/$REF/render-primer.sh" -o /opt/tribes/render-primer.sh 2>/dev/null || true
fi
# Report LOUDLY when the renderer is missing: a 404 (or an absent drive copy)
# previously fell through silently and left the primer un-rendered on every box,
# which is exactly how this shipped inert once. Name the ref so the cause is
# obvious.
if [ -f /opt/tribes/render-primer.sh ]; then
  chmod +x /opt/tribes/render-primer.sh 2>/dev/null || true
  sh /opt/tribes/render-primer.sh ||
    echo "[primer] render-primer.sh FAILED on first boot" >&2
else
  echo "[primer] no render-primer.sh on the drive or at ref '$REF' — primer NOT rendered" >&2
fi

# --- config -----------------------------------------------------------------
# The committed seed .codex/config.toml has two layers:
#   1. trust/yolo (approval_policy, sandbox_mode, [projects."/root/workspace"]) —
#      ALWAYS keep; the microVM is the security boundary, so codex must be
#      fully non-interactive regardless of which provider it talks to.
#   2. proxy routing (model, model_provider, [model_providers.tribes]) — only
#      valid when the metered proxy env is present.
# Proxy present  → fill the proxy placeholders, keep the whole file.
# BYO (proxy env unset) → strip ONLY the proxy bits so codex falls back to its
#      own provider/creds while staying auto-approved + trusted. No raw
#      __TRIBES_* placeholders survive either way.
# Both edits are local: no install, no network, nothing to fetch at switch time.
# Gate on a provider placeholder (provider placeholder from the in-VM P-256 key, via
# the platform-provided OpenRouter placeholder) so a keyless BYO/external box strips the proxy bits below;
# the token itself is env-only for codex (OPENAI_API_KEY, exported in launch.sh).
token="${OPENROUTER_API_KEY:-}"
if [ -n "$TRIBES_LLM_MODEL" ] && [ -n "$token" ]; then
  sed -i "s|__TRIBES_PROXY__|https://openrouter.ai/api/v1|g" "$HOME/.codex/config.toml"
  sed -i "s|__TRIBES_MODEL__|$TRIBES_LLM_MODEL|g" "$HOME/.codex/config.toml"
elif [ -e "$HOME/.codex/config.toml" ]; then
  # Strip the proxy bits with awk: drop the top-level model/model_provider keys
  # and the whole [model_providers.*] table, keeping trust/yolo untouched.
  #
  # This used to prefer a structured `bun -e` edit via smol-toml, which meant
  # `bun add smol-toml` — a NETWORK INSTALL at switch time, on the one path this
  # harness is supposed to have nothing left to install. The seed config.toml is
  # OURS and committed, so its whitespace and key order are not adversarial
  # input: awk over a file we wrote is sufficient, and it is offline. The awk was
  # already here as the fallback and already shipping; it is now the only path.
  awk '
    /^[[:space:]]*\[model_providers/ { skip=1; next }
    /^[[:space:]]*\[/               { skip=0 }
    skip                            { next }
    /^[[:space:]]*model[[:space:]]*=/          { next }
    /^[[:space:]]*model_provider[[:space:]]*=/ { next }
    { print }
  ' "$HOME/.codex/config.toml" > "$HOME/.codex/config.toml.tmp" &&
    mv "$HOME/.codex/config.toml.tmp" "$HOME/.codex/config.toml"
fi

# --- safety net -------------------------------------------------------------
# Belt-and-suspenders: no file under /root/workspace may survive with a raw
# __TRIBES_* placeholder (broken/invalid config). AGENTS.md only carries
# __HOST__ and __EMAIL__ (both filled above), so it is not matched.
# NEVER delete *.sh — bootstrap.sh/launch.sh legitimately contain __TRIBES_ in
# their sed patterns/fallbacks; only NON-script files with a raw placeholder are
# broken config and get removed.
grep -rl "__TRIBES_" /root/workspace "$HOME/.codex" 2>/dev/null | while IFS= read -r f; do
  case "$f" in *.sh) ;; *) rm -f "$f" ;; esac
done

# --- shared agent skills (single source of truth, installed at boot) --------
# Install the skill set read-only under /root/skills and wire the native
# (claude/pi) or AGENTS.md loaders. Drive-first (#1914): the shared read-only
# /opt/harnesses drive bakes the pinned catalog AND this installer, so a stock
# boot runs the baked copy and needs no network for skills. The installer is
# fetched only when the drive predates skills (old image, dev backend) or a
# pinned TRIBES_HARNESS_REF (QA) must exercise that branch's own installer.
# Runs after all config writes; fully tolerant, so it never blocks or fails
# the boot.
if [ -z "${TRIBES_HARNESS_REF:-}" ] && [ -f /opt/harnesses/skills/install-skills.sh ]; then
  sh /opt/harnesses/skills/install-skills.sh || true
else
  curl -fsSL --max-time 20 "$RAW_BASE/${TRIBES_HARNESS_REF:-main}/install-skills.sh" | sh || true
fi
