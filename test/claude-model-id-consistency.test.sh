#!/bin/sh
# claude's on-disk settings and its launcher must agree on the tier model ids, and
# both must use the gateway-namespaced form.
#
# claude is pointed at OpenRouter's Anthropic Messages surface:
#
#   claude/launch.sh
#     proxy="https://openrouter.ai/api"
#     export ANTHROPIC_BASE_URL="$proxy"
#     export ANTHROPIC_MODEL="$TRIBES_LLM_MODEL"        # anthropic/claude-sonnet-4.6
#
# That endpoint requires the `vendor/model` form. bootstrap.sh fills settings.json's
# ANTHROPIC_MODEL from $TRIBES_LLM_MODEL, so it inherits the right shape — but the
# THREE TIER ids in settings.json were hardcoded bare (`claude-opus`) while launch.sh
# exported namespaced ones (`anthropic/claude-opus-4.8`). Two sources of one fact,
# disagreeing, with launch.sh's own comment asserting the settings block "covers the
# same values".
#
# It is latent under `launch.sh`, whose exports win for the launched process. It is
# NOT latent for a user who runs `claude` directly from the shell — a `/model opus`
# then sends a bare id to a gateway that does not know it.
#
# terminal#2926 closed as not-fixable (the retirement banner is upstream); this is the
# real defect found in the same file while establishing that.
set -u

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SETTINGS="$REPO/claude/.claude/settings.json"
LAUNCH="$REPO/claude/launch.sh"

fail=0
note() { printf '  FAIL  %s\n' "$1"; fail=1; }
pass() { printf '  ok    %s\n' "$1"; }

echo "claude model-id consistency"

for f in "$SETTINGS" "$LAUNCH"; do
  if [ ! -e "$f" ]; then
    note "missing $f"
    exit 1
  fi
done

# Extract the value each source gives a tier. Fixed-string matching throughout:
# the ids contain '/' and '.', and we care about literals, not patterns.
settings_value() {
  # "ANTHROPIC_DEFAULT_OPUS_MODEL": "<value>"
  sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SETTINGS" | head -1
}
launch_value() {
  # export ANTHROPIC_DEFAULT_OPUS_MODEL="<value>"
  sed -n 's/.*export '"$1"'="\([^"]*\)".*/\1/p' "$LAUNCH" | head -1
}

for var in ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL; do
  s="$(settings_value "$var")"
  l="$(launch_value "$var")"

  if [ -z "$s" ]; then
    note "$var absent from settings.json"
    continue
  fi
  if [ -z "$l" ]; then
    note "$var absent from launch.sh"
    continue
  fi

  if [ "$s" = "$l" ]; then
    pass "$var agrees in both sources ($s)"
  else
    note "$var disagrees — settings.json='$s' launch.sh='$l'"
  fi

  # The gateway needs vendor/model. A bare id is silently wrong: it only surfaces
  # when a user switches tier outside launch.sh.
  case "$s" in
    */*) pass "$var settings.json uses the gateway-namespaced form" ;;
    *) note "$var settings.json='$s' is not namespaced; OpenRouter's Anthropic surface needs vendor/model" ;;
  esac
done

# The claim in launch.sh that the two sources carry the same values is only safe to
# keep while they actually do — which the assertions above enforce.
if grep -q 'covers the same values' "$LAUNCH"; then
  pass "launch.sh's 'covers the same values' claim is backed by the checks above"
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "FAIL — claude's tier model ids are inconsistent or not gateway-namespaced."
  exit 1
fi

echo
echo "ok — claude tier model ids agree and are gateway-namespaced."
