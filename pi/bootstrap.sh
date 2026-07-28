#!/bin/sh
# Pi harness bootstrap — runs ONCE on first boot, as root, cwd /root/workspace, sh.
# Pi is fully FILE-based: it reads $HOME/.pi/agent/{models,settings}.json,
# so there is NO env-based config to defer to launch.sh. The two config files are
# COMMITTED real files (seed files) carrying placeholders; this script only fills
# the handful of runtime values it can't commit (proxy base, token, default model).
# The LIVE model catalog is fetched per-boot in launch.sh (not one-shot here), so a
# first-boot GET /models transient self-heals on the next boot; this script only
# SEEDS a valid models.json with the default model. Skip the proxy fill gracefully
# when the proxy env is absent (the CLI then falls back to the user's own creds).
# Config paths are $HOME-relative — the dispatcher decides HOME (old: workspace, new: /root).
set -e

# --- install ----------------------------------------------------------------
command -v pi >/dev/null 2>&1 ||
  { npm install -g --no-fund --no-audit @earendil-works/pi-coding-agent@latest && (pi update || true); }

# --- seed the shared agent primer -------------------------------------------
# Seed the shared agent primer from the repo root (single source of truth).
RAW_BASE="$(echo "${TRIBES_HARNESS_REPO:-https://github.com/tribes-protocol/ai-harness-setup}" | sed 's#//github\.com#//raw.githubusercontent.com#')"
REF="${TRIBES_HARNESS_REF:-${HOST_HARNESS_REF:-68adbaccc020d97b8b62a6f400c8283b22ecae07}}"
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
# Pi → an openai-completions provider declared in models.json. Pi does NOT
# auto-discover models for a custom provider, so the model catalog must be embedded.
# That catalog fetch now lives in launch.sh (it re-runs EVERY boot so a first-boot
# GET /models transient self-heals next boot instead of being baked in permanently).
# Here we only SEED models.json with the single default model, so the file is valid
# + usable before launch.sh's first fetch and never traps a raw placeholder.
# Read the per-sandbox provider placeholder: a short provider placeholder signed by the in-VM
# P-256 agent key (the platform-provided OpenRouter placeholder). Empty on a keyless BYO/external box, so the
# proxy fill is skipped and pi falls back to the user's own provider/creds.
token="${OPENROUTER_API_KEY:-}"
if [ -n "$TRIBES_LLM_MODEL" ] && [ -n "$token" ]; then
  proxy="https://openrouter.ai/api/v1"

  # Seed the array CONTENTS for "models": [ ... ] with the default model only;
  # launch.sh replaces this with the live catalog on the first (and every) boot.
  pi_models="{ \"id\": \"$TRIBES_LLM_MODEL\" }"

  # Fill the seed files. Substitute via awk literal gsub (NOT sed) so values that
  # contain '/', '&', or other regex/replacement metacharacters — proxy URL, JSON
  # model objects — are inserted verbatim and the result stays valid JSON.
  fill() {
    # fill <file> <placeholder> <value>
    awk -v ph="$2" -v val="$3" '
      { while ((i = index($0, ph)) > 0)
          $0 = substr($0, 1, i - 1) val substr($0, i + length(ph))
        print }
    ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
  }

  m="$HOME/.pi/agent/models.json"
  s="$HOME/.pi/agent/settings.json"
  fill "$m" "__TRIBES_PROXY__" "$proxy"
  fill "$m" "__TRIBES_TOKEN__" "$token"
  fill "$m" "__TRIBES_MODELS__" "$pi_models"
  fill "$s" "__TRIBES_MODEL__" "$TRIBES_LLM_MODEL"
else
  # No proxy env (BYO key) — never leave raw placeholders on disk. models.json is
  # ONLY the tribes provider, so drop it; pi falls back to its own provider/creds.
  # settings.json carries "theme" (pi's Automatic mode = follow the terminal's
  # light/dark), which is independent of our proxy — KEEP it, but drop the now-dead
  # defaultProvider/defaultModel that referenced the absent tribes provider.
  rm -f "$HOME/.pi/agent/models.json"
  s="$HOME/.pi/agent/settings.json"
  [ -e "$s" ] && command -v bun >/dev/null 2>&1 &&
    bun -e '
      const f = process.argv[1];
      const s = require(f);
      delete s.defaultProvider;
      delete s.defaultModel;
      require("fs").writeFileSync(f, JSON.stringify(s));
    ' "$s" || true
fi

# --- safety net -------------------------------------------------------------
# Belt-and-suspenders: no file under /root/workspace may survive with a raw
# __TRIBES_* placeholder (broken/invalid config). AGENTS.md only carries
# __HOST__ and __EMAIL__ (both filled above), so it is not matched.
# NEVER delete *.sh — bootstrap.sh/launch.sh legitimately contain __TRIBES_ in
# their sed patterns/fallbacks; only NON-script files with a raw placeholder are
# broken config and get removed.
grep -rl "__TRIBES_" /root/workspace "$HOME/.pi" 2>/dev/null | while IFS= read -r f; do
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
  # NEVER `| sh`, and NEVER a mutable ref (#2948 / #2937). `curl | sh` executes a
  # TRUNCATED transfer as root — the shell runs whatever bytes arrived. Download to
  # a file at the ref $REF already resolved above (guest pin -> host pin -> the last
  # reviewed release), require the complete file (install-skills.sh ends with a
  # literal `exit 0`; test/runtime-supply-chain-pins.test.sh locks that contract),
  # and only then run it.
  sk="$(mktemp 2>/dev/null || echo /tmp/install-skills.$$)"
  if curl -fsSL --max-time 20 "$RAW_BASE/$REF/install-skills.sh" -o "$sk" 2>/dev/null &&
     [ -s "$sk" ] && [ "$(tail -n 1 "$sk")" = "exit 0" ]; then
    sh "$sk" || true
  else
    echo "[skills] installer fetch failed or INCOMPLETE at ref '$REF' — skills NOT installed" >&2
  fi
  rm -f "$sk"
fi
