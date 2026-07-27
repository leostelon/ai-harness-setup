#!/bin/sh
# Skills authoring contract — an sh-level mirror of the invariants the downstream
# consumer (tribes-protocol/trading-harness's tests/skills/SkillsContract.test.ts)
# enforces against the vendored copies of skills/*/SKILL.md. Running it HERE means
# an authoring mistake fails in this repo's CI, not in trading-harness's sync PR.
#
# Invariants (per skills/<slug>/SKILL.md):
#   1. frontmatter keys are a subset of {name, description, allowed-tools,
#      disable-model-invocation}
#   2. allowed-tools is EXACTLY `bash read`
#   3. name equals the directory name
#   4. the body (after the frontmatter) starts with an H1 (`# `)
#   5. the file is <= 300 lines
#   6. every `<slug>/SKILL.md` cross-reference resolves to a real skill slug
#
# POSIX sh. Run: sh test/skills-contract.test.sh
set -u

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SKILLS="$REPO/skills"

fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

ALLOWED=" name description allowed-tools disable-model-invocation "

if [ ! -d "$SKILLS" ] || [ -z "$(ls "$SKILLS" 2>/dev/null)" ]; then
  fail "no skills/ directory or it is empty"
  printf '\n%d check(s) failed\n' "$fails"
  exit 1
fi

# Print the frontmatter block (between the opening and closing `---`).
frontmatter() { awk 'NR==1{next} /^---[[:space:]]*$/{exit} {print}' "$1"; }

for dir in "$SKILLS"/*/; do
  [ -d "$dir" ] || continue
  slug="$(basename "$dir")"
  f="$dir/SKILL.md"

  if [ ! -f "$f" ]; then
    fail "$slug: missing SKILL.md"
    continue
  fi

  # Must open with a `---` frontmatter fence.
  if [ "$(sed -n '1p' "$f")" != "---" ]; then
    fail "$slug: file does not open with a --- frontmatter fence"
    continue
  fi

  # 1. frontmatter keys subset of the allowed set.
  keys="$(frontmatter "$f" | sed -n 's/^\([A-Za-z][A-Za-z-]*\):.*/\1/p')"
  badkey=""
  for k in $keys; do
    case "$ALLOWED" in *" $k "*) ;; *) badkey="$k" ;; esac
  done
  if [ -n "$badkey" ]; then
    fail "$slug: frontmatter has disallowed key '$badkey'"
  else
    pass "$slug: frontmatter keys are within the allowed set"
  fi

  # 2. allowed-tools is exactly `bash read`.
  at="$(frontmatter "$f" | sed -n 's/^allowed-tools:[[:space:]]*//p' | head -n1 | sed 's/[[:space:]]*$//')"
  if [ "$at" = "bash read" ]; then
    pass "$slug: allowed-tools is exactly 'bash read'"
  else
    fail "$slug: allowed-tools is '$at', expected 'bash read'"
  fi

  # 3. name equals the directory name.
  name="$(frontmatter "$f" | sed -n 's/^name:[[:space:]]*//p' | head -n1 | sed 's/[[:space:]]*$//')"
  if [ "$name" = "$slug" ]; then
    pass "$slug: name matches the directory name"
  else
    fail "$slug: name is '$name', expected '$slug'"
  fi

  # 4. body starts with an H1.
  first="$(awk 'f && NF { print; exit } /^---[[:space:]]*$/ { if (NR>1) f=1 }' "$f")"
  case "$first" in
    "# "*) pass "$slug: body starts with an H1" ;;
    *) fail "$slug: body does not start with an H1 (got: '$first')" ;;
  esac

  # 5. <= 300 lines.
  lines="$(wc -l < "$f" | tr -d ' ')"
  if [ "$lines" -le 300 ]; then
    pass "$slug: $lines lines (<= 300)"
  else
    fail "$slug: $lines lines (> 300)"
  fi

  # 6. cross-references resolve to real slugs. The charset ADMITS A DOT because a
  # slug may carry one (zipbox-x.com). Without it no match can begin at the `z` of
  # "zipbox-x.com/SKILL.md" — every backtrack hits the dot — so the extractor falls
  # through to the `c` and reports an unresolvable ref named "com", blaming the file
  # that HOLDS the reference rather than the skill it points at.
  refs="$(grep -oE '[a-z0-9][a-z0-9.-]*/SKILL\.md' "$f" 2>/dev/null | sed 's#/SKILL\.md##' | sort -u)"
  for ref in $refs; do
    if [ -d "$SKILLS/$ref" ]; then
      pass "$slug: cross-reference '$ref' resolves"
    else
      fail "$slug: cross-reference '$ref' does not resolve to a real skill"
    fi
  done
done

if [ "$fails" -ne 0 ]; then
  printf '\n%d check(s) failed\n' "$fails"
  exit 1
fi
printf '\nall skills-contract checks passed\n'
