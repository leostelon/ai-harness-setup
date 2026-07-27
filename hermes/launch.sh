#!/bin/sh
# Hermes harness launch — runs on EVERY launch, as root, cwd /root/workspace, sh.
# Hermes is fully FILE-based (config.yaml), so there is NO env-based config to
# export here. We re-sed the display.skin line from the CURRENT theme so a
# live theme so a browser light/dark toggle takes effect on relaunch. The ^  skin: anchor matches both
# the initial __TRIBES_SKIN__ placeholder and a previously-set value, so relaunch
# toggles work. Then exec hermes with --yolo (bypasses dangerous-command
# approvals; the microVM is the security boundary).
# The ^  skin: line is present in BOTH configs bootstrap.sh can produce: the full
# proxy config and the BYO skin-only config (display block only). Guard on [ -f ]
# anyway so a missing file never makes sed -i create/break one.
# Config paths are $HOME-relative — the dispatcher decides HOME (old: workspace,
# new: /root).
# --- re-render the agent primer (restore-safety, like the token refresh) -----
# bootstrap.sh's sed CONSUMED the primer placeholders, freezing whatever the box
# knew at first boot: the boot-slug hostname (a claim adds a DNS alias and never
# renames the VM) and "none" identity values if the agent_identities row wasn't
# bound yet. AGENTS.md is auto-loaded into the agent's context, so a frozen primer
# feeds it a WRONG public URL by default. Re-render from the untouched template
# with this launch's live env so both self-heal and survive restore.
if [ -e /opt/tribes/render-primer.sh ]; then
  sh /opt/tribes/render-primer.sh ||
    echo "[primer] render-primer.sh FAILED — primer may be stale" >&2
else
  # Loud on purpose: `2>/dev/null || true` here once turned "my dependency was
  # never installed" into silence, and the primer fix sat INERT on every box
  # through review, a Fable pass and four ref moves. A missing renderer means the
  # harness install fetched the wrong ref — say so.
  echo "[primer] /opt/tribes/render-primer.sh MISSING — primer NOT refreshed (harness install incomplete / wrong ref?)" >&2
fi

# Prefer the LIVE theme the in-VM bridge writes to /run/tribes-theme on every
# browser attach and every theme frame, so a mid-session light/dark toggle takes
# effect on the next hermes launch; fall back to the create-time TRIBES_THEME when
# that file is absent. Same order grok/launch.sh uses, and the reason it matters
# is that TRIBES_THEME is fixed when the box is CREATED: reading it alone pinned
# hermes' skin to whatever the browser was showing at create time forever. It is
# also 'auto' now whenever the user chose to follow the system, which is not a
# colour — the [ = light ] test below correctly resolves that to dark, and
# /run/tribes-theme supplies the real answer on every launch a browser has touched.
if [ -f "$HOME/.hermes/config.yaml" ]; then
  theme="$(cat /run/tribes-theme 2>/dev/null)"
  [ "$theme" = light ] || [ "$theme" = dark ] || theme=$([ "$TRIBES_THEME" = light ] && echo light || echo dark)
  skin=$([ "$theme" = light ] && echo daylight || echo default)
  sed -i "s|^  skin:.*|  skin: $skin|" "$HOME/.hermes/config.yaml"
fi

# --- restore-safety: refresh the proxy token from the LIVE env --------------
# The placeholder is a provider placeholder supplied in-VM by the platform-provided OpenRouter placeholder (signed
# with the P-256 agent key). bootstrap.sh baked one into config.yaml (api_key) on
# first boot; it goes stale (expiry, or a PAUSE -> RESTORE onto a disk holding the
# previous boot's token), so refresh and re-point the on-disk api_key every launch.
# Match the api_key field value so the swap works for any prior token (a placeholder has no
# sed-special chars). No-op on a cold boot; skipped on a keyless BYO/unset box.
token="${OPENROUTER_API_KEY:-}"
if [ -n "$token" ] && [ -f "$HOME/.hermes/config.yaml" ]; then
  sed -i "s|api_key: \"[^\"]*\"|api_key: \"$token\"|" "$HOME/.hermes/config.yaml"
fi

# --- seal the venv against banner-time lazy installs ------------------------
# hermes-agent's startup show_banner() -> get_tool_definitions() runs EVERY
# toolset's requirements check_fn, and the TTS check (check_tts_requirements ->
# _import_edge_tts) — plus the browser check — trigger a BLOCKING `pip install`
# of optional deps (edge-tts, Playwright Chromium) on EVERY launch. They never
# persist in this rootfs, so each relaunch re-attempts the slow install, which
# floods/stalls startup and breaks the exit->bash->relaunch cycle (the dropped
# bash can't hold while the relaunched hermes is mid-install). This env var is
# hermes-agent's own opt-out (the upstream Docker image sets it): the checks then
# report the tool "unavailable" instead of installing, so hermes boots instantly.
# Core LLM chat + its tools are unaffected; only optional audio/browser tools that
# need extra runtime deps are skipped — fine for a microVM agent.
export HERMES_DISABLE_LAZY_INSTALLS=1

# --- BYO onboarding: land on the setup wizard, not a bare [Y/n] prompt -------
# In BYO mode (no proxy env) bootstrap.sh wrote a skin-only config — hermes has
# no provider/key, and `hermes --yolo` parks on a plain "Hermes isn't configured
# yet ... Run setup now? [Y/n]" text line. Launch `hermes setup` DIRECTLY on the
# first BYO boot so the user lands in real onboarding (Nous OAuth quick setup /
# bring-your-own-keys). The /opt/tribes marker keeps a user who backs out from
# being re-trapped on every relaunch (they can rerun `hermes setup` anytime),
# and a completed setup writes providers into config.yaml, which also skips.
if [ -z "$token" ] \
   && ! grep -q '^providers:' "$HOME/.hermes/config.yaml" 2>/dev/null \
   && [ ! -e /opt/tribes/.hermes-setup-offered ]; then
  mkdir -p /opt/tribes && : > /opt/tribes/.hermes-setup-offered
  hermes setup || true
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
  curl -fsSL --max-time 10 "$SKILLS_RAW_BASE/${TRIBES_HARNESS_REF:-main}/install-skills.sh" | sh || true
fi

# --- close the direct-provider escape hatch (#2255) --------------------------
# On a platform-funded box the control plane injects a PLACEHOLDER OPENROUTER_API_KEY
# (SandboxBootEnv.ts) intended for an egress injector that swaps in the real key.
# On zipbox no such injector is on this path, so the placeholder is just a stray
# credential-shaped env var: harnesses that auto-register a provider on env
# presence alone (pi, opencode) can pick OpenRouter DIRECTLY and 401 against
# openrouter.ai instead of using the metered proxy. Dropping it before exec leaves
# the metered proxy as the only route the harness can see.
#
# We do NOT set HTTP_PROXY/HTTPS_PROXY: the forwarder catalog is a CONNECT
# allowlist that 403s every non-catalog authority, so a blanket proxy would break
# github/npm/apt/pypi on every box.
#
# The unset is deliberately guard-scoped, NOT value-scoped (i.e. not "unset only
# if it looks like the placeholder"). Value-matching would couple this script to a
# literal defined in another repo's catalog — a silent no-op the day that value
# changes — and, worse, it would PRESERVE a real OpenRouter key that reached a
# platform-funded box some other way, which is exactly the unmetered bypass this
# closes. byoKey is the supported way to bring your own key, and it is suppressed
# by the guard below.
#
# The guard is the by-construction one: SandboxBootEnv writes TRIBES_LLM_MODEL
# ONLY for proxy-mode, non-byoKey, non-'external' boxes, so BYO/external boxes
# never enter this branch and keep their own OPENROUTER_API_KEY untouched. This is
# structural, not a special case — do not add a byoKey conditional here.
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

if [ -n "${ZIPBOX_EGRESS_PROXY_URL:-}" ]; then
  export HTTPS_PROXY="$ZIPBOX_EGRESS_PROXY_URL"
  export HTTP_PROXY="$ZIPBOX_EGRESS_PROXY_URL"
fi

exec hermes --yolo
