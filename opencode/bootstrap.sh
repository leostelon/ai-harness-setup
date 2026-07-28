#!/bin/sh
# opencode harness bootstrap — runs ONCE on first boot, as root, cwd /root/workspace, sh.
# Installs the opencode CLI and fills the SEEDED file-based config
# ($HOME/.config/opencode/opencode.json, copied verbatim from this harness
# dir with __...__ placeholders): the yolo permission, theme, and the proxy
# provider with the embedded model catalog.
# opencode config is entirely FILE-based — theme:"system" follows the terminal —
# so launch.sh just execs it; there is nothing to export per launch. Config paths
# are $HOME-relative — the dispatcher decides HOME (old: workspace, new: /root).
set -e

# --- install ----------------------------------------------------------------
command -v opencode >/dev/null 2>&1 ||
  npm install -g --no-fund --no-audit opencode-ai@latest

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
# opencode → @ai-sdk/openai-compatible provider (appends /chat/completions to
# baseURL). The top-level "permission": "allow" approves every tool in the TUI
# with no prompt (the auto-approve flag exists only on the headless `opencode
# run` subcommand, not the interactive TUI; opencode has no trust-folder gate).
# opencode does NOT auto-discover models for a fully-custom provider — it only
# knows the models declared in the config's "models" map, so `model: tribes/<id>`
# won't resolve without it and opencode silently drops to its built-in default.
# So fetch the catalog from the proxy's GET /models and embed it as the models
# map (like pi). If the fetch is empty (boot-time hiccup), declare at least the
# default model so the preselected `model` still resolves.
CFG="$HOME/.config/opencode/opencode.json"
mkdir -p "$HOME/.config/opencode"

token="${OPENROUTER_API_KEY:-}"
if [ -n "$TRIBES_LLM_MODEL" ] && [ -n "$token" ] && [ -e "$CFG" ]; then
  proxy="https://openrouter.ai/api/v1"
  oc_models=$(
    set -- -s --max-time 10
    if [ -n "${ZIPBOX_EGRESS_PROXY_URL:-}" ]; then
      set -- "$@" --proxy "$ZIPBOX_EGRESS_PROXY_URL"
    fi
    curl "$@" "$proxy/models" -H "Authorization: Bearer $token" 2>/dev/null |
      grep -oE '"id":[[:space:]]*"[^"]+"' |
      sed -E 's/.*"([^"]+)"$/"\1": {}/' | paste -sd, -
  )
  [ -n "$oc_models" ] || oc_models="\"$TRIBES_LLM_MODEL\": {}"

  # Substitute the placeholders into the seeded config. The model-catalog map
  # is arbitrary JSON (quotes, braces, commas), so pass every replacement
  # value through the environment and let awk do a literal (non-regex) swap —
  # no sed delimiter or shell-quoting hazards. Result is written atomically.
  TRIBES_PROXY="$proxy" TRIBES_TOKEN="$token" \
  TRIBES_MODEL="$TRIBES_LLM_MODEL" TRIBES_MODELS="$oc_models" \
  awk '
    function repl(line, tok, val,   i) {
      while ((i = index(line, tok)) > 0)
        line = substr(line, 1, i - 1) val substr(line, i + length(tok))
      return line
    }
    {
      $0 = repl($0, "__TRIBES_PROXY__",  ENVIRON["TRIBES_PROXY"])
      $0 = repl($0, "__TRIBES_TOKEN__",  ENVIRON["TRIBES_TOKEN"])
      $0 = repl($0, "__TRIBES_MODELS__", ENVIRON["TRIBES_MODELS"])
      $0 = repl($0, "__TRIBES_MODEL__",  ENVIRON["TRIBES_MODEL"])
      print
    }
  ' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
else
  # No proxy env (or the seed is missing) — leave a minimal valid trusted config
  # so the TUI is auto-approved and follows the terminal theme, with NO leftover
  # __...__ tokens; the CLI then falls back to the user's own key.
  cat > "$CFG" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "permission": "allow",
  "theme": "system"
}
EOF
fi

# --- safety net -------------------------------------------------------------
# Belt-and-suspenders: no file under /root/workspace may survive with a raw
# __TRIBES_* placeholder (broken/invalid config). AGENTS.md only carries
# __HOST__ and __EMAIL__ (both filled above), so it is not matched.
# NEVER delete *.sh — bootstrap.sh/launch.sh legitimately contain __TRIBES_ in
# their sed patterns/fallbacks; only NON-script files with a raw placeholder are
# broken config and get removed.
grep -rl "__TRIBES_" /root/workspace "$HOME/.config/opencode" 2>/dev/null | while IFS= read -r f; do
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
