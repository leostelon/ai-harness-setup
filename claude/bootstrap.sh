#!/bin/sh
# claude harness — bootstrap (runs ONCE, as root, cwd /root/workspace, under sh).
# Installs the Claude Code binary and stamps the host into the primer. All
# FILE-based config (.claude.json trust file, .claude/settings.json) ships as
# committed real files in this harness dir, copied verbatim into /root/workspace by
# the dispatcher, then relocated to $HOME (old dispatcher: stays in the workspace;
# new dispatcher: moves to /root). settings.json's "env" block carries the proxy
# config (ANTHROPIC_BASE_URL/AUTH_TOKEN/MODEL) filled below — this is what a
# MANUALLY-typed `claude` in the exit shell reads, since launch.sh's own `export`s
# die with the harness process and never reach that shell. launch.sh still
# exports the same values too (belt-and-suspenders for the auto-launched harness)
# and refreshes the on-disk token every launch (restore-safety).

set -e

# --- install the harness binary ---------------------------------------------
# Gate on the binary already being present: sandbox rootfs images pre-install the
# harness onto a shared read-only drive on PATH, so first boot skips the install
# and writes only config (matches every other harness's bootstrap).
command -v claude >/dev/null 2>&1 ||
  npm install -g --no-fund --no-audit @anthropic-ai/claude-code@latest || true

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
# obvious. claude also reads CLAUDE.md — the renderer mirrors the primer into it.
if [ -f /opt/tribes/render-primer.sh ]; then
  chmod +x /opt/tribes/render-primer.sh 2>/dev/null || true
  TRIBES_PRIMER_ALSO_CLAUDE_MD=1 sh /opt/tribes/render-primer.sh ||
    echo "[primer] render-primer.sh FAILED on first boot" >&2
else
  echo "[primer] no render-primer.sh on the drive or at ref '$REF' — primer NOT rendered" >&2
fi

# --- proxy config (settings.json "env" block) -------------------------------
# Proxy present  → fill the three placeholders so settings.json's env block is a
#      real, working gateway config claude reads on EVERY invocation (launched OR
#      manually typed in the exit shell). Filled via awk literal gsub (NOT sed) so
#      the proxy URL/token — which may contain '/', '&', or other regex/
#      replacement metacharacters — are inserted verbatim and the result stays
#      valid JSON (mirrors pi/bootstrap.sh's fill()).
# BYO (proxy env unset) → strip the WHOLE "env" key so claude falls back to the
#      user's own login/key with zero leftover proxy creds and zero raw
#      __TRIBES_* placeholders. Structured edit via bun (always present on the
#      sandbox rootfs, unlike node/npm) so theme/skipDangerousModePermissionPrompt
#      survive untouched; falls back to an awk line-range delete if bun is
#      somehow unavailable. settings.json commits "env" as the FIRST key
#      specifically so that fallback's line range (open brace to matching close)
#      is unambiguous.
CFG="$HOME/.claude/settings.json"
# Read the per-sandbox provider placeholder (provider placeholder from the in-VM P-256 key).
# Empty on a keyless BYO/external box → the env block is stripped below.
token="${OPENROUTER_API_KEY:-}"
if [ -n "$TRIBES_LLM_MODEL" ] && [ -n "$token" ] && [ -e "$CFG" ]; then
  fill() {
    # fill <file> <placeholder> <value>
    awk -v ph="$2" -v val="$3" '
      { while ((i = index($0, ph)) > 0)
          $0 = substr($0, 1, i - 1) val substr($0, i + length(ph))
        print }
    ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
  }
  fill "$CFG" "__TRIBES_PROXY__" "https://openrouter.ai/api"
  fill "$CFG" "__TRIBES_TOKEN__" "$token"
  fill "$CFG" "__TRIBES_MODEL__" "$TRIBES_LLM_MODEL"
elif [ -e "$CFG" ]; then
  command -v bun >/dev/null 2>&1 && bun -e '
    const f = process.argv[1];
    const s = require(f);
    delete s.env;
    require("fs").writeFileSync(f, JSON.stringify(s));
  ' "$CFG" || true
  # Fallback: if a raw __TRIBES_ placeholder survived (e.g. bun unavailable),
  # delete the "env": { ... } block by line range so the safety net below does
  # not nuke the whole file and lose theme/skipDangerousModePermissionPrompt.
  if grep -q "__TRIBES_" "$CFG" 2>/dev/null; then
    awk '
      /^[[:space:]]*"env": \{/ { skip=1; next }
      skip && /^[[:space:]]*\},?[[:space:]]*$/ { skip=0; next }
      skip { next }
      { print }
    ' "$CFG" > "$CFG.tmp" &&
      mv "$CFG.tmp" "$CFG"
  fi
fi

# --- safety net -------------------------------------------------------------
# Belt-and-suspenders: no file under /root/workspace may survive with a raw
# __TRIBES_* placeholder. AGENTS.md/CLAUDE.md only carry __HOST__ and __EMAIL__ (both filled above), so they are
# not matched.
# NEVER delete *.sh — bootstrap.sh/launch.sh legitimately contain __TRIBES_ in
# their sed patterns/fallbacks; only NON-script files with a raw placeholder are
# broken config and get removed.
grep -rl "__TRIBES_" /root/workspace "$HOME/.claude.json" "$HOME/.claude" 2>/dev/null | while IFS= read -r f; do
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
