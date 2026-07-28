#!/bin/sh
# grok harness — bootstrap (runs ONCE, as root, cwd /root/workspace, under sh).
# Installs the xAI grok CLI and stamps the host into AGENTS.md. grok's only
# FILE-based config is its theme (.grok/config.toml, committed as a SEED FILE with
# a __TRIBES_THEME__ placeholder) — we fill that placeholder HERE from the
# create-time TRIBES_THEME so the file is valid (no raw placeholder) and survives
# the end-of-bootstrap safety net. launch.sh re-seds it each launch so a theme
# toggle takes effect on relaunch. grok's proxy is ENV-only (GROK_* vars), in launch.sh.
# Config paths are $HOME-relative — the dispatcher decides HOME (old: workspace,
# new: /root).

set -e

# --- install the harness binary ---------------------------------------------
# RUNTIME half of #2947 (tracked as #2948). This block used to be
# `curl https://x.ai/cli/install.sh | GROK_BIN_DIR=/usr/local/bin bash`: an
# unauthenticated, unpinned vendor script piped into a ROOT shell inside a live
# tenant VM, with no integrity check of any kind.
#
# It is NOT dead code. It is gated on `command -v grok` missing, and that is
# exactly the state an EMPTY harness delta produces — so on any box whose delta
# shipped empty this fired on the first switch to grok. dockers/Dockerfile.harnesses
# in the terminal repo closed the identical hole on the BAKE surface; this closes
# it on the guest.
#
# Same treatment as the bake: fetch the VERSION-ADDRESSED artifact (the vendor's
# own documented download — `install.sh <version>` fetches this exact URL) and
# verify it against a pinned digest BEFORE it becomes executable.
#
# FAIL CLOSED. A fetch failure, a missing sha256sum, or a digest MISMATCH all skip
# the install and say so on stderr. The box is then a grok harness with no grok —
# which is precisely the state it was already in when this branch was reached, so
# nothing is lost, and unverified vendor bytes never run as root. Never add a
# fallback to the unpinned installer here; that would restore the whole defect.
#
# Keep GROK_VERSION/GROK_SHA256 in step with dockers/Dockerfile.harnesses in
# tribes-protocol/terminal, which pins the same artifact for the drive bake.
# To bump: pick a version from https://x.ai/cli/stable, then
#   curl -fsSL https://x.ai/cli/grok-<version>-linux-x86_64 | sha256sum
GROK_VERSION=0.2.112
GROK_SHA256=c2867112f7d89366123fe68a55a23dfb027d3602fc5b5b9cd5c080dacb4a2503
if ! command -v grok >/dev/null 2>&1; then
  echo "Installing grok $GROK_VERSION (first boot of this sandbox)..."
  gt=/tmp/grok.$$
  if ! command -v sha256sum >/dev/null 2>&1; then
    echo "[grok] sha256sum unavailable — refusing to install unverified vendor bytes" >&2
  elif curl -fsSL --retry 3 --max-time 300 -o "$gt" \
         "https://x.ai/cli/grok-${GROK_VERSION}-linux-x86_64" 2>/dev/null &&
       echo "${GROK_SHA256}  $gt" | sha256sum -c - >/dev/null 2>&1; then
    install -m 0755 "$gt" /usr/local/bin/grok || true
  else
    echo "[grok] pinned artifact $GROK_VERSION unavailable or DIGEST MISMATCH — grok NOT installed" >&2
  fi
  rm -f "$gt"
fi

# --- fill the theme placeholder (FILE config) -------------------------------
# .grok/config.toml ships as a SEED with theme = "__TRIBES_THEME__". Substitute
# the create-time theme so the committed file ends up CONCRETE (light/dark) — no
# raw placeholder left for the safety net below to delete. Default dark.
theme=$([ "$TRIBES_THEME" = light ] && echo light || echo dark)
if [ -e "$HOME/.grok/config.toml" ]; then
  sed -i "s|__TRIBES_THEME__|$theme|g" "$HOME/.grok/config.toml"
fi

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

# --- safety net -------------------------------------------------------------
# Belt-and-suspenders: no file under /root/workspace may survive bootstrap with a raw
# __TRIBES_* placeholder. grok's ONLY placeholder (__TRIBES_THEME__ in
# .grok/config.toml) is now filled above, so the config is CONCRETE and is NOT
# matched here. AGENTS.md only carries __HOST__ and __EMAIL__ (both filled above), so it is not matched either. This
# only fires if some file slips through unfilled.
# NEVER delete *.sh — bootstrap.sh/launch.sh legitimately contain __TRIBES_ in
# their sed patterns/fallbacks; only NON-script files with a raw placeholder are
# broken config and get removed.
grep -rl "__TRIBES_" /root/workspace "$HOME/.grok" 2>/dev/null | while IFS= read -r f; do
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
