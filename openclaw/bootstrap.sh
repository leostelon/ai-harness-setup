#!/bin/sh
# OpenClaw harness bootstrap — runs ONCE on first boot, as root, cwd /root/workspace, sh.
# Installs the OpenClaw CLI and fills the committed seed config. OpenClaw is fully
# FILE-based — there is no env-based config — so launch.sh just execs it. The two
# committed files are .openclaw/exec-approvals.json (fully static yolo defaults)
# and .openclaw/openclaw.json (proxy provider + the live model catalog), the
# latter carrying placeholders this script fills. Config paths are $HOME-relative
# — the dispatcher decides HOME (old: workspace, new: /root).
set -e

# --- install ----------------------------------------------------------------
command -v openclaw >/dev/null 2>&1 ||
  npm install -g --no-fund --no-audit openclaw@latest

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

# --- platform-funded config ----------------------------------------------------
# Fill the committed seed .openclaw/openclaw.json placeholders. OpenClaw uses a
# custom openai-completions provider (appends /chat/completions) and REQUIRES it
# to declare its models as an array of {id,name} objects — a provider with no
# models is rejected as invalid ("custom model providers must declare models")
# and openclaw exits to a shell. It does NOT auto-discover, so fetch the catalog
# from the proxy's GET /models and embed each id (reusing id as name); fall back
# to just the default model if the fetch hiccups at boot. Skip gracefully if the
# proxy env is absent — the placeholders are left untouched and the CLI falls
# back to whatever creds the user supplies.
token="${OPENROUTER_API_KEY:-}"
if [ -n "$TRIBES_LLM_MODEL" ] && [ -n "$token" ]; then
  proxy="https://openrouter.ai/api/v1"
  claw_models=$(
    set -- -s --max-time 10
    if [ -n "${ZIPBOX_EGRESS_PROXY_URL:-}" ]; then
      set -- "$@" --proxy "$ZIPBOX_EGRESS_PROXY_URL"
    fi
    curl "$@" "$proxy/models" -H "Authorization: Bearer $token" 2>/dev/null |
      grep -oE '"id":[[:space:]]*"[^"]+"' |
      sed -E 's/.*"([^"]+)"$/{"id": "\1", "name": "\1"}/' | paste -sd, -
  )
  [ -n "$claw_models" ] || claw_models="{\"id\": \"$TRIBES_LLM_MODEL\", \"name\": \"$TRIBES_LLM_MODEL\"}"

  # Substitute every placeholder via awk so the catalog array (which contains
  # slashes, braces and quotes) is injected verbatim — no sed-delimiter clash.
  # awk's gsub replacement treats `&` and `\` specially, so escape them in each
  # value first; the placeholders are then replaced literally and JSON stays valid.
  cfg="$HOME/.openclaw/openclaw.json"
  awk \
    -v proxy="$proxy" -v token="$token" \
    -v model="$TRIBES_LLM_MODEL" -v models="$claw_models" '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/&/, "\\&", s); return s }
    BEGIN { proxy=esc(proxy); token=esc(token); model=esc(model); models=esc(models) }
    {
      gsub(/__TRIBES_PROXY__/, proxy)
      gsub(/__TRIBES_TOKEN__/, token)
      gsub(/__TRIBES_MODEL__/, model)
      gsub(/__TRIBES_MODELS__/, models)
      print
    }
  ' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
else
  # No proxy env (BYO key) — never leave raw placeholders on disk. Drop the
  # proxy-provider seed (keep the static exec-approvals.json); openclaw then
  # uses its own provider/creds.
  rm -f "$HOME/.openclaw/openclaw.json"
fi

# --- safety net -------------------------------------------------------------
# Belt-and-suspenders: no file under /root/workspace may survive with a raw
# __TRIBES_* placeholder (broken/invalid config). AGENTS.md only carries
# __HOST__ and __EMAIL__ (both filled above), so it is not matched.
# NEVER delete *.sh — bootstrap.sh/launch.sh legitimately contain __TRIBES_ in
# their sed patterns/fallbacks; only NON-script files with a raw placeholder are
# broken config and get removed.
grep -rl "__TRIBES_" /root/workspace "$HOME/.openclaw" 2>/dev/null | while IFS= read -r f; do
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
