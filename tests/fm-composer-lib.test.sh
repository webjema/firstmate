#!/usr/bin/env bash
# tests/fm-composer-lib.test.sh - the shared composer-content classifier
# (bin/fm-composer-lib.sh), the ONE fleet-wide owner every backend adapter
# delegates its empty|pending|unknown verdict to.
#
# The load-bearing contract, task fm-composer-shellglyph-safety:
#   1. A BARE shell prompt glyph (`>`/`$`/`%`/`#`) on an unstructured row is a
#      dead shell, NOT an empty agent composer - it must read `unknown`
#      (unsafe-for-injection), never `empty`. This is the safety fix.
#   2. The SAME shell glyph INSIDE a bordered composer box is the harness's own
#      prompt and still reads `empty` (existing behavior preserved).
#   3. The AGENT prompt glyphs `❯` (claude) and `›` (codex) are a genuine empty
#      agent composer either way, bordered or bare.
#   4. Real unsubmitted text reads `pending`; a known idle placeholder reads
#      `empty`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"

# classify <bordered> <content> [idle_re] -> echoes the verdict.
classify() { fm_composer_classify_content "$@"; }

# --- Safety fix: bare shell prompt is NOT an empty agent composer -----------

test_bare_shell_glyphs_are_unknown() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g")
    [ "$out" = unknown ] \
      || fail "bare shell glyph '$g' must read unknown (dead shell, unsafe), got '$out'"
  done
  pass "fm_composer_classify_content: a bare shell prompt glyph (>/\$/%/#) reads unknown, never empty"
}

test_stripped_unbordered_content_uses_plain_content() {
  local plain out
  for plain in '$' 'user@host $'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = unknown ] \
      || fail "stripped unbordered content '$plain' must retain its unknown safety verdict, got '$out'"
  done
  for plain in '❯' '›'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = empty ] \
      || fail "a stripped agent glyph '$plain' must remain empty, got '$out'"
  done
  pass "fm_composer_classify_content: stripped unbordered content is unknown except verified agent glyphs"
}

test_bare_shell_prompt_with_command_is_not_empty() {
  local out
  # A dead shell showing a typed command must not read empty either.
  out=$(classify 0 '$ ls -la')
  [ "$out" != empty ] || fail "a bare shell prompt with a command must not read empty, got '$out'"
  pass "fm_composer_classify_content: a bare shell prompt carrying a command is not empty"
}

# --- Preserved: shell glyph inside a composer box is the harness prompt ------

test_bordered_shell_glyph_is_empty() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 1 "$g")
    [ "$out" = empty ] \
      || fail "a shell glyph '$g' inside a bordered composer box must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: a bare prompt glyph inside a bordered composer box reads empty (claude's own idle composer)"
}

# --- Agent glyphs are empty either way --------------------------------------

test_agent_glyphs_are_empty_bordered_and_bare() {
  local out
  out=$(classify 0 '❯'); [ "$out" = empty ] || fail "bare claude '❯' should read empty, got '$out'"
  out=$(classify 0 '›'); [ "$out" = empty ] || fail "bare codex '›' should read empty, got '$out'"
  out=$(classify 1 '❯'); [ "$out" = empty ] || fail "bordered claude '❯' should read empty, got '$out'"
  out=$(classify 1 '›'); [ "$out" = empty ] || fail "bordered codex '›' should read empty, got '$out'"
  pass "fm_composer_classify_content: agent prompt glyphs (❯ claude, › codex) read empty bordered or bare"
}

# --- Empty content and idle placeholder -------------------------------------

test_empty_content_is_empty() {
  local out
  out=$(classify 0 ''); [ "$out" = empty ] || fail "empty bare content should read empty, got '$out'"
  out=$(classify 1 ''); [ "$out" = empty ] || fail "empty bordered content should read empty, got '$out'"
  pass "fm_composer_classify_content: an empty composer reads empty"
}

test_idle_placeholder_is_empty() {
  local idle='^Type a message\.\.\.$' out
  # Placeholder with no prompt glyph (grok's bordered empty composer).
  out=$(classify 1 'Type a message...' "$idle")
  [ "$out" = empty ] || fail "the grok idle placeholder should read empty, got '$out'"
  # Placeholder after an agent glyph (post-strip match).
  out=$(classify 0 '❯ Type a message...' "$idle")
  [ "$out" = empty ] || fail "the idle placeholder after a glyph should read empty, got '$out'"
  # Without the idle regex it is just text -> pending.
  out=$(classify 1 'Type a message...')
  [ "$out" = pending ] || fail "without an idle regex the placeholder text is pending, got '$out'"
  pass "fm_composer_classify_content: a known idle placeholder reads empty, before and after glyph stripping"
}

test_idle_placeholder_case_mode_is_explicit() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'type a message...' "$idle")
  [ "$out" = pending ] || fail "a case-variant idle placeholder should remain pending by default, got '$out'"
  out=$(classify 1 'type a message...' "$idle" insensitive)
  [ "$out" = empty ] || fail "an explicitly insensitive idle placeholder should read empty, got '$out'"
  pass "fm_composer_classify_content: idle matching preserves the caller's case mode"
}

# --- Real text is pending ---------------------------------------------------

test_real_text_is_pending() {
  local out
  out=$(classify 0 '❯ fix findings 1 and 3'); [ "$out" = pending ] || fail "bare '❯ <text>' should be pending, got '$out'"
  out=$(classify 1 '> deploy staging now'); [ "$out" = pending ] || fail "bordered '> <text>' should be pending, got '$out'"
  # A slash-command popup argument-hint placeholder is still unsubmitted text.
  out=$(classify 1 '/compact compaction instructions'); [ "$out" = pending ] || fail "a popup placeholder fill should be pending, got '$out'"
  pass "fm_composer_classify_content: real unsubmitted text reads pending (including a popup argument-hint fill)"
}

# --- Regression: unicode whitespace in the composer row ---------------------
# Incident afk-wake-fix-r4 (2026-07-26). These bytes are not a construction:
# they are the literal cursor row captured from the wedged supervisor pane with
# `tmux capture-pane -p -e | cat -A`, which read
#     ^[[37mM-bM-^]M-/M-BM- ^[[39m$
# i.e. ESC[37m, U+276F '❯', U+00A0 NO-BREAK SPACE, ESC[39m. claude pads its
# composer with U+00A0, which no `[[:space:]]` trim strips, so the row read as
# real unsubmitted text and the away-mode injector - including its max-defer
# FORCE escape, which never clobbers a `pending` line - refused to deliver for
# 26,211 seconds. Anything that makes this row read `pending` again is that
# outage.

# The exact incident row, built from its captured bytes (octal escapes keep the
# invisible U+00A0 out of this source, where nobody could see it).
incident_row() { printf '\033[37m\342\235\257\302\240\033[39m'; }

# Run a raw styled row through the same two extractors the tmux adapter uses,
# then classify - so the test exercises the real path, not a hand-trimmed string.
classify_row() {  # <raw-styled-row> <bordered>
  local raw=$1 bordered=${2:-0} plain stripped
  plain=$(printf '%s\n' "$raw" | fm_composer_strip_ansi)
  stripped=$(printf '%s\n' "$raw" | fm_composer_strip_ghost)
  fm_composer_classify_content "$bordered" "$stripped" '' insensitive "$plain"
}

test_incident_row_with_nbsp_is_empty() {
  local out
  out=$(classify_row "$(incident_row)")
  [ "$out" = empty ] \
    || fail "the captured incident row (❯ + U+00A0) must read empty, got '$out' - this is the 26,211s wedge"
  pass "fm_composer_classify_content: the real captured '❯'+U+00A0 composer row reads empty"
}

test_nbsp_padding_does_not_hide_an_empty_composer() {
  local nbsp out
  nbsp=$(printf '\302\240')
  # Padded on both sides, and a row of nothing but NBSP.
  out=$(classify 0 "${nbsp}❯${nbsp}${nbsp}")
  [ "$out" = empty ] || fail "NBSP-padded agent glyph must read empty, got '$out'"
  out=$(classify 0 "${nbsp}${nbsp}")
  [ "$out" = empty ] || fail "a row of only NBSP must read empty, got '$out'"
  # The bordered composer box must still match when its padding is NBSP.
  out=$(classify 1 "> ${nbsp}")
  [ "$out" = empty ] || fail "bordered shell glyph with NBSP padding must read empty, got '$out'"
  pass "fm_composer_normalize_ws: NBSP padding never hides an empty composer"
}

test_other_unicode_whitespace_is_normalized() {
  local out u
  # U+2009 thin space, U+202F narrow NBSP, U+3000 ideographic space, and the
  # zero-width U+200B / U+FEFF, each after an agent glyph.
  for u in '\0342\0200\0211' '\0342\0200\0257' '\0343\0200\0200' '\0342\0200\0213' '\0357\0273\0277'; do
    out=$(classify 0 "❯$(printf '%b' "$u")")
    [ "$out" = empty ] \
      || fail "agent glyph followed by unicode whitespace $u must read empty, got '$out'"
  done
  pass "fm_composer_normalize_ws: space-like and zero-width unicode never read as typed text"
}

test_nbsp_does_not_swallow_real_typed_text() {
  local nbsp out
  nbsp=$(printf '\302\240')
  # The protection that must NOT regress: normalization makes whitespace
  # uniform, it does not make content disappear.
  out=$(classify 0 "❯${nbsp}fix findings 1 and 3")
  [ "$out" = pending ] || fail "real text after an NBSP gap must stay pending, got '$out'"
  out=$(classify 0 "${nbsp}deploy staging now")
  [ "$out" = pending ] || fail "NBSP-led real text must stay pending, got '$out'"
  pass "fm_composer_normalize_ws: real typed text after unicode whitespace still reads pending"
}

# --- The bare-glyph-between-rules claude composer shape ---------------------
# The current claude composer is not the older bordered `│ > … │` box: it is a
# bare `❯` row sandwiched between two full-width `─` rules, with the top rule
# sometimes carrying a title (on the incident night: "Configure supplier email
# and live-run budget settings"). Only the cursor row is ever classified, so the
# rules and their title are not part of the decision - but that is a property
# worth pinning, because a future reader looking at the shape may assume the
# title text reaches the classifier.

test_bare_glyph_between_rules_is_empty() {
  local rule out
  rule=$(printf '\342\224\200%.0s' 1 2 3 4 5 6 7 8 9 10)
  # The composer row itself, whatever the rules above and below it carry.
  out=$(classify_row "$(incident_row)")
  [ "$out" = empty ] || fail "the bare-glyph composer row must read empty, got '$out'"
  # A rule row is not a composer box border: it must not read as `bordered`,
  # and on its own it is not an empty agent composer either.
  out=$(classify 0 "$rule")
  [ "$out" = pending ] \
    || fail "a lone horizontal rule row is not an empty composer, got '$out'"
  # With border-title text present, still nothing changes for the cursor row.
  out=$(classify 0 "${rule} Configure supplier email and live-run budget settings ${rule}")
  [ "$out" = pending ] \
    || fail "a titled rule row is not an empty composer, got '$out'"
  pass "fm_composer_classify_content: the bare-glyph-between-rules composer row reads empty, titled or not"
}

test_bare_shell_glyphs_are_unknown
test_stripped_unbordered_content_uses_plain_content
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_agent_glyphs_are_empty_bordered_and_bare
test_empty_content_is_empty
test_idle_placeholder_is_empty
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending
test_incident_row_with_nbsp_is_empty
test_nbsp_padding_does_not_hide_an_empty_composer
test_other_unicode_whitespace_is_normalized
test_nbsp_does_not_swallow_real_typed_text
test_bare_glyph_between_rules_is_empty
