#!/bin/sh
set -eu

REPO="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
HARNESSES="claude pi codex grok hermes openclaw opencode cline"
failures=0

pass() {
  printf 'PASS %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1" >&2
  failures=$((failures + 1))
}

for harness in $HARNESSES; do
  launch="$REPO/$harness/launch.sh"
  if grep -q 'OPENROUTER_API_KEY' "$launch"; then
    pass "$harness consumes the provider placeholder"
  else
    fail "$harness lost the provider placeholder"
  fi

  if grep -q 'ZIPBOX_EGRESS_PROXY_URL' "$launch" &&
    grep -q 'export HTTPS_PROXY="$ZIPBOX_EGRESS_PROXY_URL"' "$launch" &&
    grep -q 'export HTTP_PROXY="$ZIPBOX_EGRESS_PROXY_URL"' "$launch"; then
    pass "$harness configures explicit proxy mode"
  else
    fail "$harness does not configure explicit proxy mode"
  fi

  if grep -q 'unset OPENROUTER_API_KEY' "$launch"; then
    fail "$harness removes the billing placeholder"
  else
    pass "$harness preserves the billing placeholder"
  fi
done

if grep -Rqs '/llm/proxy' \
  "$REPO/claude" "$REPO/pi" "$REPO/codex" "$REPO/grok" \
  "$REPO/hermes" "$REPO/openclaw" "$REPO/opencode" "$REPO/cline" \
  "$REPO/CONTRACT.md"; then
  fail "legacy LLM route remains"
else
  pass "legacy LLM route is absent"
fi

if grep -Rqs 'tribes-agent-token' \
  "$REPO/claude" "$REPO/pi" "$REPO/codex" "$REPO/grok" \
  "$REPO/hermes" "$REPO/openclaw" "$REPO/opencode" "$REPO/cline"; then
  fail "an LLM harness still mints a terminal bearer"
else
  pass "LLM harnesses do not mint terminal bearers"
fi

if ! grep -Rqs 'https://openrouter.ai/api/v1' \
  "$REPO/pi" "$REPO/codex" "$REPO/grok" "$REPO/hermes" \
  "$REPO/openclaw" "$REPO/opencode" "$REPO/cline"; then
  fail "OpenAI-compatible harness endpoint is absent"
else
  pass "OpenAI-compatible harnesses use OpenRouter"
fi

if grep -Rqs 'https://openrouter.ai/api' "$REPO/claude"; then
  pass "Claude uses OpenRouter Anthropic compatibility"
else
  fail "Claude OpenRouter endpoint is absent"
fi

[ "$failures" -eq 0 ]
