#!/bin/sh
# cursor harness — bootstrap (runs ONCE, as root, cwd /root/workspace, under sh).
# Installs the Cursor CLI (cursor.com/cli). Cursor has NO custom base-URL
# support — the CLI always routes through Cursor's own backend — so there is NO
# metered-proxy config anywhere in this harness: it is BYO-Cursor-account
# (in-TUI `/login`, or CURSOR_API_KEY). The non-interactive config
# (.cursor/cli-config.json: approvalMode unrestricted + cursor's own sandbox
# disabled — the microVM is the security boundary) ships as a committed real
# file in this harness dir, copied verbatim into /root/workspace by the dispatcher,
# then — like every other harness's dot-config — relocated to $HOME (the
# dispatcher decides HOME: old dispatcher leaves it in the workspace, new
# dispatcher moves it to /root). cursor-agent reads its config from the actual
# HOME env var at runtime, so no path in this script needs to know which.
set -e

# --- install the harness binary ---------------------------------------------
# The official installer unpacks a self-contained build under
# $HOME/.local/share/cursor-agent and symlinks `agent` into $HOME/.local/bin —
# no root or Node needed. Pin HOME=/root/workspace for the INSTALL regardless of
# what HOME the dispatcher runs this script with, so the binary always lands on
# the persistent workspace disk (.local/ is never relocated by the dispatcher —
# only the dot-config dirs are). /root/workspace/.local/bin is not on the
# dispatcher's PATH, so also expose the entry symlink at /usr/local/bin, which
# always is.
# Exposed as `cursor`, NOT `agent`. Every harness delta overlays into the SAME
# /opt/harnesses tree, so a generic name collides with any other harness that
# ships one — grok's installer drops an `agent` too, and the bake's disjointness
# gate rejects the conflict (`./bin/agent <- cursor grok`). Each harness's
# entrypoint is named after the harness. Keep this in step with
# dockers/Dockerfile.harnesses in the terminal repo, which bakes bin/cursor.
command -v cursor >/dev/null 2>&1 ||
  curl -fsS https://cursor.com/install | HOME=/root/workspace bash || true
[ -x /root/workspace/.local/bin/agent ] &&
  ln -sf /root/workspace/.local/bin/agent /usr/local/bin/cursor || true

# --- seed the shared agent primer -------------------------------------------
# Seed the shared agent primer from the repo root (single source of truth).
# cursor reads AGENTS.md natively (it also reads CLAUDE.md — same content, so
# one file is enough; do not duplicate).
RAW_BASE="$(echo "${TRIBES_HARNESS_REPO:-https://github.com/tribes-protocol/ai-harness-setup}" | sed 's#//github\.com#//raw.githubusercontent.com#')"
REF="${TRIBES_HARNESS_REF:-${HOST_HARNESS_REF:-main}}"
# Cache the PLACEHOLDER-BEARING primer + the renderer outside the workspace, then
# render. Bootstrap runs ONCE and its sed consumes the placeholders, so stamping
# them here alone froze the wrong values for the life of the disk: the guest's
# hostname is the boot slug (a claim never renames the VM), and a box bootstrapped
# before its identity row is bound has no TRIBES_IDENTITY_* and froze "none".
# launch.sh re-runs the renderer every launch so both self-heal.
mkdir -p /opt/tribes 2>/dev/null || true
curl -fsSL "$RAW_BASE/$REF/AGENTS.md" -o /opt/tribes/AGENTS.md.tmpl 2>/dev/null || true
# Fetch LOUDLY: a 404 here (e.g. the ref lacks this file) previously fell
# through silently and left the primer un-rendered on every box, which is
# exactly how this shipped inert. Report the ref so the cause is obvious.
if curl -fsSL "$RAW_BASE/$REF/render-primer.sh" -o /opt/tribes/render-primer.sh 2>/dev/null; then
  chmod +x /opt/tribes/render-primer.sh 2>/dev/null || true
  sh /opt/tribes/render-primer.sh ||
    echo "[primer] render-primer.sh FAILED on first boot" >&2
else
  echo "[primer] could not fetch render-primer.sh from ref '$REF' — primer NOT rendered" >&2
fi

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
