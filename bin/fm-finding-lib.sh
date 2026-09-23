# shellcheck shell=bash
# The one contract shared by the two halves of a finding's life: bin/fm-file-finding.sh
# FILES a fleet finding under a machine-drainable hold, and bin/fm-triage-findings.sh
# DRAINS it. That hold is the whole coupling between them, and it lives here so neither
# script hard-codes the other's spelling of it.
# Usage: . bin/fm-finding-lib.sh
#
# The contract: a fleet finding awaiting automated triage is held with tasks-axi kind
# `parked` and a reason that STARTS WITH `verify:`. tasks-axi knows only five hold kinds
# (captain|external|load|parked|future), so `verify` cannot be a kind of its own and rides
# in the reason instead; `parked` is the kind that carries it. The DRAIN keys on the prefix
# alone, so the text after `verify:` is a human-readable note and may be reworded freely
# without breaking detection - which is why the filer writes the full reason and the drain
# never compares it whole. A `parked` hold whose reason does NOT start with `verify:` is
# some other tool's hold and the drain leaves it untouched.

# The canonical reason the filer writes. The drain matches on the `verify:` prefix, not this
# whole string, so rewording the tail is safe; keep the prefix.
# shellcheck disable=SC2034  # read by the scripts that source this lib, not within it.
FM_VERIFY_HOLD_REASON="verify: awaiting automated triage - bin/fm-triage-findings.sh"
FM_VERIFY_HOLD_KIND="parked"

# True when a hold (kind, reason) is a verify hold this drain owns.
fm_is_verify_hold() {  # <hold-kind> <hold-reason>
  [ "$1" = "$FM_VERIFY_HOLD_KIND" ] || return 1
  case "$2" in
    verify:*) return 0 ;;
    *) return 1 ;;
  esac
}

# A captain hold reason must be one paren-free line: tasks-axi delimits the reason with
# parens in its row format and refuses them in the value. Collapse whitespace, drop parens,
# and cap the length so the question stays a scannable row, not a paragraph. The full
# question also lands in the finding body, so nothing is lost to this trim.
fm_sanitize_reason() {  # <text>
  printf '%s' "$1" | tr '\n\t' '  ' | tr -d '()' | tr -s ' ' | sed 's/^ //; s/ $//' | cut -c1-180
}
