#!/usr/bin/env bash
# Tests for bin/fm-repo-url-lib.sh and the pool key that depends on it.
#
# THE INCIDENT (2026-08-28). One repository, github.com/Symanty/OptiroqAllma, occupied
# FOUR treehouse pools holding 41.3 GB across 25 slots, because four callers spelled its
# remote URL three different ways and treehouse keys a pool directory on the literal
# string. The four spellings and their measured pool names are pinned in case (a); if
# that case ever fails, the box is fragmenting again.
#
#   (a) the four real spellings collapse to one identity and ONE pool key
#   (b) the canonical form: scheme, userinfo, default port, host case, .git, slash
#   (c) repositories that are genuinely different STAY different
#   (d) local path remotes keep their path identity - `.git` is a real directory name
#   (e) fm_repo_url_same: an absent origin is not an identity
#   (f) the guard: no `remote get-url` site in bin/ derives an identity from a raw URL
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=bin/fm-repo-url-lib.sh disable=SC1091
. "$ROOT/bin/fm-repo-url-lib.sh"
# shellcheck source=bin/fm-pool-lib.sh disable=SC1091
. "$ROOT/bin/fm-pool-lib.sh"

CLI="$ROOT/bin/fm-repo-url.sh"
TMP_ROOT=$(fm_test_tmproot fm-repo-url)

canon() { fm_repo_url_canonical "$1"; }

# --- (a) the four real spellings --------------------------------------------
#
# Measured on the box that produced the incident: the pool directory is
# `<clone basename>-<first 6 hex of sha256(origin URL)>`, so these four spellings
# hashed to 9ae0cf, 80b6c6, bca1f1 and 84584f and split one repo across four pools.
SPELLINGS="
https://github.com/Symanty/OptiroqAllma.git
https://github.com/Symanty/OptiroqAllma
https://github.com/Symanty/OptiroqAllma/
git@github.com:Symanty/OptiroqAllma.git
"
EXPECTED_IDENTITY=github.com/Symanty/OptiroqAllma

for u in $SPELLINGS; do
  got=$(canon "$u")
  [ "$got" = "$EXPECTED_IDENTITY" ] \
    || fail "(a) '$u' canonicalised to '$got', expected '$EXPECTED_IDENTITY'"
  got=$("$CLI" canonical "$u")
  [ "$got" = "$EXPECTED_IDENTITY" ] \
    || fail "(a) fm-repo-url.sh canonical '$u' printed '$got', expected '$EXPECTED_IDENTITY'"
done
pass "(a) all four real spellings canonicalise to one identity"

# The acceptance criterion is about the POOL KEY, not just the string, so drive it
# through real clones. The basename is the other half of treehouse's key, so these
# share one directory name - which is exactly what the consolidation plan has to
# arrange for the live pools.
KEYS=""
n=0
for u in $SPELLINGS; do
  n=$((n + 1))
  home="$TMP_ROOT/keys/$n"
  mkdir -p "$home"
  fm_git_init_commit "$home/optiroq"
  git -C "$home/optiroq" remote add origin "$u"
  KEYS="$KEYS$(fm_pool_key "$(cd "$home/optiroq" && pwd -P)")
"
done
uniq_keys=$(printf '%s' "$KEYS" | LC_ALL=C sort -u | grep -c .)
[ "$uniq_keys" = 1 ] \
  || fail "(a) four spellings produced $uniq_keys distinct pool keys, expected 1:"$'\n'"$KEYS"
pass "(a) four spellings of one repo produce one identical pool key: $(printf '%s' "$KEYS" | head -n 1)"

# --- (b) the canonical form -------------------------------------------------
check() {  # <url> <expected> <label>
  local got
  got=$(canon "$1")
  [ "$got" = "$2" ] || fail "(b) $3: '$1' -> '$got', expected '$2'"
}
check 'https://GitHub.COM/Org/Repo'          'github.com/Org/Repo'   'host lowercased, path not'
check 'ssh://git@github.com/Org/Repo.git'    'github.com/Org/Repo'   'ssh scheme and userinfo dropped'
check 'https://user:pw@github.com/Org/Repo'  'github.com/Org/Repo'   'userinfo with a password dropped'
check 'https://github.com:443/Org/Repo'      'github.com/Org/Repo'   'default https port dropped'
check 'ssh://git@github.com:22/Org/Repo'     'github.com/Org/Repo'   'default ssh port dropped'
check 'https://github.com:8443/Org/Repo'     'github.com:8443/Org/Repo' 'non-default port kept'
check 'git://github.com/Org/Repo.git'        'github.com/Org/Repo'   'git scheme'
check 'https://github.com/Org/Repo.git/'     'github.com/Org/Repo'   'trailing slash after .git'
check 'https://github.com/Org/Repo//'        'github.com/Org/Repo'   'repeated trailing slashes'
check 'https://github.com'                   'github.com'            'host with no path'
check ''                                     ''                      'empty in, empty out'
pass "(b) the canonical form drops scheme, userinfo, default port and .git, and lowercases only the host"

# --- (c) genuinely different repositories stay different --------------------
differ() {  # <a> <b> <label>
  fm_repo_url_same "$1" "$2" \
    && fail "(c) $3: '$1' and '$2' must NOT be the same repository"
  return 0
}
differ 'https://github.com/Org/Repo' 'https://gitlab.com/Org/Repo'  'different hosts'
differ 'https://github.com/Org/Repo' 'https://github.com/Other/Repo' 'different owners'
differ 'https://github.com/Org/Repo' 'https://github.com/Org/Repo2'  'different repo names'
# Path case is deliberately NOT folded: one repo on GitHub, two on a case-sensitive
# host. bin/fm-repo-url-lib.sh's header owns this and the rest of the left-out list.
differ 'https://github.com/Org/Repo' 'https://github.com/org/repo'   'path case is not folded'
differ 'https://github.com:8443/Org/Repo' 'https://github.com/Org/Repo' 'non-default port is part of the identity'
pass "(c) different hosts, owners, names, path case and non-default ports stay distinct"

# --- (d) local path remotes -------------------------------------------------
check '/srv/git/repo.git'        '/srv/git/repo.git'  'a bare repo really is named .git'
check '/srv/git/repo/'           '/srv/git/repo'      'trailing slash stripped from a path'
check 'file:///srv/git/repo.git' '/srv/git/repo.git'  'file:// unwrapped, .git kept'
check '../sibling/repo.git'      '../sibling/repo.git' 'relative path left alone'
differ '/srv/git/repo' '/srv/git/repo.git' 'a worktree and a bare repo are different directories'
pass "(d) local path remotes keep their path identity"

# --- (e) an absent origin is not an identity --------------------------------
fm_repo_url_same '' '' && fail "(e) two absent origins must not compare as one repository"
fm_repo_url_same 'https://github.com/Org/Repo' '' \
  && fail "(e) a present origin must not match an absent one"
"$CLI" same 'https://github.com/Org/Repo.git' 'git@github.com:Org/Repo' \
  || fail "(e) the CLI must report two spellings of one repo as the same"
"$CLI" same 'https://github.com/Org/Repo' 'https://github.com/Org/Other' \
  && fail "(e) the CLI must report two different repos as different"
pass "(e) fm_repo_url_same treats an absent origin as an absence, not an identity"

# --- (f) the guard: no identity is derived from a raw URL -------------------
#
# THIS IS THE CASE THAT FAILS WHEN SOMEONE REINTRODUCES THE BUG. Every script in bin/
# that reads an origin URL is classified below. An IDENTITY site decides "which repo is
# this" - a pool key, a lock name, a same-repo comparison - and must route through
# bin/fm-repo-url-lib.sh. A PRESENCE site only asks "is there an origin at all" and
# derives nothing. A new or renamed site matches neither list and fails here, which
# forces the author to classify it rather than quietly hashing a raw string.
IDENTITY_SITES="bin/fm-pool-lib.sh bin/fm-home-seed.sh"
# repo_slug in fm-bearings-snapshot.sh parses owner/repo for `gh`, which is a GitHub
# API coordinate and not a pool identity; the rest only test that an origin exists.
PRESENCE_SITES="bin/fm-bearings-snapshot.sh bin/fm-bootstrap.sh bin/fm-ff-lib.sh
bin/fm-fleet-sync.sh bin/fm-review-diff.sh bin/fm-teardown.sh"

# Only real code counts as a site: a header comment that discusses `remote get-url`
# reads no URL, and listing it would make the inventory drift on every doc edit.
found=$( (cd "$ROOT" && grep -rlE '^[^#]*remote get-url' bin/) | LC_ALL=C sort)
declared=$(printf '%s\n%s\n' "$IDENTITY_SITES" "$PRESENCE_SITES" | tr ' ' '\n' | grep . | LC_ALL=C sort -u)
[ "$found" = "$declared" ] || fail "(f) the set of bin/ scripts reading an origin URL changed.
Classify each new or removed one in this test as an IDENTITY site (it decides WHICH
repository, and must call fm_repo_url_canonical or fm_repo_url_same) or a PRESENCE
site (it only checks that an origin exists).
--- declared ---
$declared
--- found ---
$found"

for f in $IDENTITY_SITES; do
  grep -q 'fm_repo_url_canonical\|fm_repo_url_same' "$ROOT/$f" \
    || fail "(f) $f reads an origin URL to decide which repository it is, but never routes it through bin/fm-repo-url-lib.sh"
done

# fm_pool_key is the one that produced the incident, so guard its body directly: a
# file-level grep would still pass if someone added a second, raw hashing site beside
# the canonical one.
body=$(awk '/^fm_pool_key\(\)/ {inside = 1} inside {print} inside && /^}/ {exit}' "$ROOT/bin/fm-pool-lib.sh")
[ -n "$body" ] || fail "(f) could not extract fm_pool_key's body from bin/fm-pool-lib.sh"
assert_contains "$body" 'fm_repo_url_canonical' \
  "(f) fm_pool_key must hash the canonical repository identity, not the raw remote URL"
printf '%s' "$body" | grep -q 'get-url[^)]*)[[:space:]]*|' \
  && fail "(f) fm_pool_key pipes a raw remote URL somewhere; it must canonicalise first"
pass "(f) every bin/ script that derives a repository identity routes through the shared canonicaliser"
