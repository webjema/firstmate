#!/usr/bin/env bash
# fm-wake-kind-lib.sh - THE ONE OWNER of the watcher wake vocabulary: which wake
# kinds exist, and what a wake looks like on the watcher's stdout.
#
# THE VOCABULARY IS STATED ONCE, in FM_WAKE_KINDS. Everything else here - the grep
# regex the file-scanning callers use, the string predicate the daemon uses, and the
# validator bin/fm-wake-lib.sh's fm_wake_append gates on - is DERIVED from that one
# list. Adding a kind is a one-word edit that cannot leave a consumer behind. It
# used to be four hand-written copies, and the fourth kind added (disk-guard, the
# one wake AGENTS.md section 7 says only the captain may act on) reached exactly one
# of them.
#
# WAKE LINE SHAPE. bin/fm-watch.sh's wake() echoes its reason verbatim, so a wake
# line is either "<kind>: <payload>" or a BARE "<kind>" - heartbeat and disk-guard
# are emitted bare. Hence the ($|:) tail: a predicate that only looked for
# "disk-guard:" would match nothing the watcher ever writes.
#
# SIDE-EFFECT-FREE LEAF, deliberately. It sets no FM_ROOT/FM_HOME/STATE and creates
# no directory, because its three consumers source it from three contexts where
# doing so would be wrong: bin/fm-watch-checkpoint.sh resolves no home of its own,
# and bin/fm-supervise-daemon.sh sources it at TOP LEVEL - before fm_super_main has
# decided which home's state it owns, and in the pure-classifier form
# tests/fm-daemon.test.sh sources. That is why the vocabulary lives here rather than
# beside fm_wake_append in bin/fm-wake-lib.sh, which does resolve and mkdir state.

FM_WAKE_KINDS='signal stale check heartbeat disk-guard'

# ERE matching a wake line, for the file-scanning callers:
#   grep -Eq "$FM_WAKE_LINE_RE" "$watcher_output"
# Built without a command substitution: every consumer sources this at its own top
# level, and the watcher is started once per checkpoint, so a fork here would be pure
# cost for a string that never changes.
_fm_wake_line_re_init() {
  local kind alt=''
  for kind in $FM_WAKE_KINDS; do
    alt="${alt:+$alt|}$kind"
  done
  FM_WAKE_LINE_RE="^($alt)(\$|:)"
}
_fm_wake_line_re_init
unset -f _fm_wake_line_re_init

# The same question asked of a string rather than a file, so the two call shapes
# cannot drift into disagreeing about what a wake is.
fm_is_wake_reason() {  # <line>
  [[ $1 =~ $FM_WAKE_LINE_RE ]]
}

# Is <kind> a kind at all? The gate on what may enter the durable wake queue.
fm_wake_kind_valid() {  # <kind>
  local kind
  for kind in $FM_WAKE_KINDS; do
    if [ "$1" = "$kind" ]; then return 0; fi
  done
  return 1
}
