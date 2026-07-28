#!/bin/sh
# Hermes harness bootstrap — runs ONCE on first boot, as root, cwd /root/workspace, sh.
# Installs the Hermes CLI, then fills the placeholders in the COMMITTED seed config
# $HOME/.hermes/config.yaml. Hermes is fully FILE-based: it reads
# model/provider/skin from that file, so there is NO env-based config to defer to
# launch.sh. launch.sh re-seds the display.skin line each launch so a theme toggle
# takes effect on relaunch. Config paths are $HOME-relative — the dispatcher
# decides HOME (old: workspace, new: /root).
set -e

# --- install ----------------------------------------------------------------
# --skip-setup: the Nous installer otherwise runs an INTERACTIVE `hermes setup`
# wizard that reads /dev/tty and blocks bootstrap.sh forever (the dispatcher never
# reaches its launch loop). We seed config.yaml ourselves below, so skip the wizard.
#
# --skip-browser: this is the boot-speed fix. WITHOUT it the installer's
# `node-deps` stage runs `playwright install --with-deps chromium`, which downloads
# the ~170MB Chromium engine AND apt-installs the heavy X11/nss/atk/font system-lib
# stack — by far the slowest part of a cold boot (measured ~42s on a fast-network
# host, minutes on a slow one). A platform-funded chat agent in a microVM never drives
# a real browser, so none of that is needed on the interactive boot path. CRUCIAL:
# --skip-browser does NOT skip the node-deps the TUI needs — the installer ALWAYS
# runs `npm install` first and only gates the `playwright install chromium` step on
# this flag (see install_node_deps in the Nous install.sh). Verified empirically:
# with Chromium absent, hermes still paints its full TUI (welcome banner, input
# box, status line) — there is no degraded/spinner-gallery UI. This corrects the
# 07dcc0c revert, whose premise ("--skip-browser drops node-deps the TUI needs")
# does not hold for the current installer. (HERMES_DISABLE_LAZY_INSTALLS=1 in
# launch.sh already stops any runtime lazy re-install attempt, so the browser tool
# simply reports "unavailable" instead of blocking startup.)
#
# Redirect the installer's output to a log, NOT the terminal: the Nous install.sh
# still emits "Get:/Unpacking/Setting up" lines (python/node deps), which fill the
# in-VM bridge's scrollback; on the exit->bash reconnect the bridge REPLAYS that
# whole buffer — flooding the fresh socket so the sandboxd:validate exitToShell
# probe (a single `echo` in the dropped bash) is buried and bash looks dead. The
# other harnesses install one quiet npm/binary, so their replay is tiny; keep
# hermes's bootstrap equally quiet. `|| true` so a non-zero installer exit can't
# abort bootstrap (which would drop the once-only marker and re-run everything).
if ! command -v hermes >/dev/null 2>&1; then
  # Run the installer under `script` so it sees a PTY (isatty), then discard
  # script's OWN stdout to /var/log + /dev/null. Why both: (1) a plain
  # `... >/log 2>&1` makes the installer's stdout a NON-tty, and the Nous
  # install.sh then builds a degraded TUI (the agent comes up missing its full
  # UI), which breaks the resize check. (2) Letting it write to the terminal fills
  # the bridge scrollback with the install log, which the exit->bash reconnect
  # replays and buries the exitToShell probe. `script` gives it a real tty (full
  # TUI build) while keeping every byte off the dispatcher terminal.
  script -qec \
    'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup --skip-browser' \
    /var/log/hermes-install.log >/dev/null 2>&1 || true

  # --- post-install prune ----------------------------------------------------
  # hermes installs HERE, on first boot, onto the VM's own disk (it is no longer
  # pre-baked into the shared rootfs — the bake cost ~511MB on EVERY sandbox's
  # disk, hermes or not). Trim the payload the running agent never reads — the
  # cloned repo's git history/docs/tests, the musl twins of the glibc node
  # bindings, venv bytecode, and the npm/uv install caches — ~180MB. Same list
  # the old bake-time slim used; the boot path (venv + gnu bindings) is intact.
  # Best-effort: a miss must never abort bootstrap.
  if command -v hermes >/dev/null 2>&1; then
    H=/usr/local/lib/hermes-agent
    rm -rf "$H/.git" "$H/website" "$H/tests" "$H/apps/desktop" \
           "$HOME/.npm" "$HOME/.cache" 2>/dev/null || true
    find "$H/node_modules" -type d -name '*-musl' -prune -exec rm -rf {} + 2>/dev/null || true
    find "$H/venv" -depth -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
    find "$H/venv" -type f -name '*.pyc' -delete 2>/dev/null || true
  fi
fi

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
# Fill the seed config's placeholders. Hermes declares a user `tribes` provider in
# config.yaml's providers map and points model.provider at it (the built-in
# openai-api provider has a hardcoded Nous baseUrl, so an env override never takes
# effect — this MUST be a file). transport: chat_completions makes the OpenAI SDK
# append /chat/completions to `api`. We omit a provider `models` list so the picker
# discovers the full catalog from the proxy's GET /models; model.default preselects
# ours. Skip gracefully if the proxy env is absent (CLI falls back to user creds).
token="${OPENROUTER_API_KEY:-}"
if [ -n "$TRIBES_LLM_MODEL" ] && [ -n "$token" ]; then
  sed -i "s|__TRIBES_PROXY__|https://openrouter.ai/api/v1|g" "$HOME/.hermes/config.yaml"
  sed -i "s|__TRIBES_TOKEN__|$token|g" "$HOME/.hermes/config.yaml"
  sed -i "s|__TRIBES_MODEL__|$TRIBES_LLM_MODEL|g" "$HOME/.hermes/config.yaml"
  # Resolve the create-time skin now so no __TRIBES_SKIN__ placeholder reaches the
  # safety net below (launch.sh still re-seds the generic `skin:` line each launch
  # so a later theme toggle takes effect on relaunch).
  skin=$([ "$TRIBES_THEME" = light ] && echo daylight || echo default)
  sed -i "s|^  skin:.*|  skin: $skin|" "$HOME/.hermes/config.yaml"
else
  # No proxy env (BYO key) — drop the model:/providers: blocks so hermes falls back
  # to its built-in Nous provider/OAuth, but KEEP a skin-only display block: the
  # theme is independent of our proxy and a light-mode user must still get the
  # daylight skin. Resolve the skin now and rewrite the file to ONLY the display
  # block (no raw __TRIBES_* survives; launch.sh re-seds the same `skin:` line).
  skin=$([ "$TRIBES_THEME" = light ] && echo daylight || echo default)
  printf 'display:\n  skin: %s\n' "$skin" >"$HOME/.hermes/config.yaml"
fi

# --- safety net -------------------------------------------------------------
# Belt-and-suspenders: no file under /root/workspace may survive with a raw
# __TRIBES_* placeholder (broken/invalid config). AGENTS.md only carries
# __HOST__ and __EMAIL__ (both filled above), so it is not matched.
# NEVER delete *.sh — bootstrap.sh/launch.sh legitimately contain __TRIBES_ in
# their sed patterns/fallbacks; only NON-script files with a raw placeholder are
# broken config and get removed.
grep -rl "__TRIBES_" /root/workspace "$HOME/.hermes" 2>/dev/null | while IFS= read -r f; do
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
