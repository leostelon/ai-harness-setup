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
# RUNTIME half of #2947 (tracked as #2948). This block used to be
# `curl https://cursor.com/install | HOME=/root/workspace bash`: an
# unauthenticated, unpinned vendor script piped into a ROOT shell inside a live
# tenant VM, with no integrity check of any kind.
#
# It is NOT dead code. It is gated on `command -v cursor` missing, and that is
# exactly the state an EMPTY harness delta produces — so on any box whose delta
# shipped empty this fired on the first switch to cursor.
#
# Same treatment as the bake: cursor.com/install is ALSO the version pointer (it
# hard-codes the release it downloads), so its bytes change on every Cursor
# release and digest-pinning the SCRIPT would break on a routine vendor push.
# The ARTIFACT is pinned instead — the installer downloads exactly this URL.
#
# The extracted tree is relocatable: dist-package/cursor-agent is a bash shim that
# resolves `realpath "$0"` and execs its OWN sibling node + index.js, so it works
# through the symlink below. Land it on the persistent workspace disk (.local/ is
# never relocated by the dispatcher) and expose the entry at /usr/local/bin, which
# is on the dispatcher's PATH.
#
# Exposed as `cursor`, NOT `agent`. Every harness delta overlays into the SAME
# /opt/harnesses tree, so a generic name collides with any other harness that
# ships one — the vendor installer drops an `agent`, and the bake's disjointness
# gate rejected exactly that conflict (`./bin/agent <- cursor grok`). Fetching the
# artifact ourselves means the generic name is never created in the first place.
#
# FAIL CLOSED. A fetch failure, a missing sha256sum, or a digest MISMATCH all skip
# the install and say so on stderr — the box is then a cursor harness with no
# cursor, which is the state it was already in when this branch was reached.
# Never add a fallback to the unpinned installer here.
#
# Keep CURSOR_VERSION/CURSOR_SHA256 in step with dockers/Dockerfile.harnesses in
# tribes-protocol/terminal, which pins the same artifact for the drive bake.
# To bump: read the pinned release out of the vendor script, then hash the asset:
#   curl -fsS https://cursor.com/install | grep -o 'lab/[^/]*/' | head -1
#   curl -fsSL https://downloads.cursor.com/lab/<ver>/linux/x64/agent-cli-package.tar.gz | sha256sum
CURSOR_VERSION=2026.07.23-e383d2b
CURSOR_SHA256=702ad595213bee5df0268be9f80a19f29fcceaa2a42fc55e39f2b5199051f0c4
if ! command -v cursor >/dev/null 2>&1; then
  ct=/tmp/cursor-agent.$$.tar.gz
  if ! command -v sha256sum >/dev/null 2>&1; then
    echo "[cursor] sha256sum unavailable — refusing to install unverified vendor bytes" >&2
  elif curl -fsSL --retry 3 --max-time 300 -o "$ct" \
         "https://downloads.cursor.com/lab/${CURSOR_VERSION}/linux/x64/agent-cli-package.tar.gz" 2>/dev/null &&
       echo "${CURSOR_SHA256}  $ct" | sha256sum -c - >/dev/null 2>&1; then
    mkdir -p /root/workspace/.local/cursor
    tar --strip-components=1 -xzf "$ct" -C /root/workspace/.local/cursor || true
    [ -x /root/workspace/.local/cursor/cursor-agent ] &&
      ln -sf /root/workspace/.local/cursor/cursor-agent /usr/local/bin/cursor || true
  else
    echo "[cursor] pinned artifact $CURSOR_VERSION unavailable or DIGEST MISMATCH — cursor NOT installed" >&2
  fi
  rm -f "$ct"
fi

# --- seed the shared agent primer -------------------------------------------
# Seed the shared agent primer from the repo root (single source of truth).
# cursor reads AGENTS.md natively (it also reads CLAUDE.md — same content, so
# one file is enough; do not duplicate).
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
