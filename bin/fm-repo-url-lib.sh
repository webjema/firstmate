#!/usr/bin/env bash
# fm-repo-url-lib.sh - the single owner of "are these two remote URLs the same
# repository". Sourced by bin/fm-pool-lib.sh and bin/fm-home-seed.sh; exposed as a
# command by bin/fm-repo-url.sh.
#
# WHY THIS EXISTS (measured 2026-08-28). treehouse names a pool directory
# `<basename of the clone dir>-<first 6 hex of sha256(origin URL)>` and compares the
# URL LITERALLY, so one repository fragmented into four pools holding 41.3 GB across
# 25 slots. Verified by hashing the four live spellings against the four live pool
# names on this box:
#
#   https://github.com/Symanty/OptiroqAllma.git   9ae0cf   optiroq-dev-9ae0cf
#                                                          optiroq-allma-9ae0cf
#   https://github.com/Symanty/OptiroqAllma       80b6c6   optiroq-80b6c6
#   https://github.com/Symanty/OptiroqAllma/      bca1f1   OptiroqAllma-bca1f1
#   git@github.com:Symanty/OptiroqAllma.git       84584f   (no pool yet)
#
# THE BASENAME IS THE OTHER HALF OF THE KEY, and that is the part everything about
# this is easy to get wrong: `optiroq-dev-9ae0cf` and `optiroq-allma-9ae0cf` carry the
# SAME hash and are still two pools, because their clones sit in directories with
# different names. Canonicalising the URL therefore cannot on its own collapse pools
# that already exist - the clone directory names have to converge too. What it does do
# is stop firstmate ADDING to the fragmentation: every clone firstmate creates is born
# with the canonical spelling, and firstmate's own warm lock stops treating four
# spellings of one repository as four independent pools to fill in parallel.
#
# CANONICAL FORM: `host[:port]/path`, with the scheme, any userinfo, a default port, a
# trailing slash and a trailing `.git` removed, and the host lowercased. It is an
# IDENTITY, not a fetchable URL - never hand it to `git clone`; use
# fm_repo_url_same to compare, and keep the operator's own spelling for anything a
# human reads. bin/fm-home-seed.sh is the one exception and says why at its call site.
#
# DELIBERATELY NOT NORMALISED, each because doing so would merge repositories that are
# genuinely distinct or would need something this function must not do:
#   - PATH CASE. `Symanty/OptiroqAllma` and `symanty/optiroqallma` are one repo on
#     GitHub but two on a case-sensitive host. Folding case would silently merge them.
#   - SSH HOST ALIASES. `git@gh:org/repo` resolves through ~/.ssh/config, so deciding
#     it means `github.com` needs `ssh -G` and the caller's host config.
#   - RENAMES AND REDIRECTS. `host/old/name` 301s to `host/new/name` and is the same
#     repo; knowing that needs a network call.
#   - LOCAL PATH REMOTES keep their path as their identity: `/srv/a` and `/srv/a.git`
#     are two different directories, and a bare repo really is named `x.git`. Only
#     trailing slashes are stripped. Resolving symlinks and `..` for a local remote is
#     bin/fm-home-seed.sh's normalize_origin_url, which owns that separately.
#   - `insteadOf` REWRITING needs nothing: `git remote get-url` already applies it
#     (verified 2026-08-28), and treehouse reads the rewritten URL too, so both sides
#     see one spelling before this function is reached.
set -u

# fm_repo_url_strip_trailing_slashes <string>
fm_repo_url_strip_trailing_slashes() {
  local s=${1:-}
  while [ "${s%/}" != "$s" ]; do s=${s%/}; done
  printf '%s' "$s"
}

# fm_repo_url_canonical <url>: the repository identity of <url> on stdout. Empty in,
# empty out. Never fails: an unparseable remote canonicalises to itself with trailing
# slashes removed, which keeps it distinct from everything else rather than colliding.
fm_repo_url_canonical() {  # <url>
  local url=${1:-} scheme='' rest hostpart path port=''

  [ -n "$url" ] || return 0
  rest=$url
  case "$url" in
    *://*)
      scheme=$(printf '%s' "${url%%://*}" | tr '[:upper:]' '[:lower:]')
      rest=${url#*://}
      ;;
  esac

  # Local remotes: a `file:` URL, or no scheme and something that can only be a path.
  case "$scheme" in
    file) fm_repo_url_strip_trailing_slashes "$rest"; return 0 ;;
  esac
  if [ -z "$scheme" ]; then
    case "$rest" in
      /*|./*|../*|'~'*) fm_repo_url_strip_trailing_slashes "$rest"; return 0 ;;
    esac
  fi

  # scp-like `[user@]host:path`, which git accepts with no scheme. The colon must come
  # before any slash: in `./a:b/c` the colon is part of a path, not a host separator.
  if [ -z "$scheme" ]; then
    case "$rest" in
      *:*)
        case "${rest%%:*}" in
          */*) fm_repo_url_strip_trailing_slashes "$rest"; return 0 ;;
        esac
        rest="${rest%%:*}/${rest#*:}"
        ;;
      *) fm_repo_url_strip_trailing_slashes "$rest"; return 0 ;;
    esac
  fi

  hostpart=${rest%%/*}
  if [ "$hostpart" = "$rest" ]; then path=''; else path=${rest#*/}; fi
  case "$hostpart" in *@*) hostpart=${hostpart##*@} ;; esac
  case "$hostpart" in
    *:*) port=${hostpart##*:}; hostpart=${hostpart%:*} ;;
  esac
  hostpart=$(printf '%s' "$hostpart" | tr '[:upper:]' '[:lower:]')
  case "$scheme:$port" in
    https:443|http:80|ssh:22|git:9418) port='' ;;
  esac

  path=$(fm_repo_url_strip_trailing_slashes "${path#/}")
  path=${path%.git}
  path=$(fm_repo_url_strip_trailing_slashes "$path")

  printf '%s%s%s%s' "$hostpart" "${port:+:$port}" "${path:+/}" "$path"
}

# fm_repo_url_same <url-a> <url-b>: true when both name one repository. Two empty
# URLs are NOT the same repository - "no origin remote" is an absence, not an identity.
fm_repo_url_same() {  # <url-a> <url-b>
  local a b
  a=$(fm_repo_url_canonical "${1:-}")
  b=$(fm_repo_url_canonical "${2:-}")
  [ -n "$a" ] && [ "$a" = "$b" ]
}
