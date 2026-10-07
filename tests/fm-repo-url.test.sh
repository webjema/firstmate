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
check '  https://github.com/Org/Repo.git  '  'github.com/Org/Repo'   'surrounding whitespace'
# The ssh user is dropped for a URL with a scheme and kept for an scp path, because
# only the scp path is relative to that user's home. bin/fm-repo-url-lib.sh owns why.
check 'git@github.com:Org/Repo.git'          'github.com/Org/Repo'   'the forge git@ doorway is dropped'
check 'alice@host:repo.git'                  'alice@host/repo'       'a non-git scp user is kept'
check 'ssh://alice@host/srv/repo.git'        'host/srv/repo'         'a non-git ssh:// user is dropped'
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
# ~alice/repo.git and ~bob/repo.git are two repositories on one host.
differ 'alice@host:repo.git' 'bob@host:repo.git' 'two ssh users on one host'
pass "(c) different hosts, owners, names, path case, ssh users and non-default ports stay distinct"

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

# --- (g) no external command, so nothing can fail into a merge ---------------
#
# A command substitution whose command is missing yields the EMPTY STRING and no error.
# When the case-fold was `| tr`, a stripped PATH emptied the host and merged unrelated
# repositories - and emptied the scheme, which sent every https:// URL down the
# unparseable path and reverted the whole fix in silence. tests/fm-pool-warm.test.sh
# sources its way in with PATH stripped, so this is a state the fleet reaches.
G_URLS="https://github.com/Symanty/OptiroqAllma.git
https://GitHub.COM/Symanty/OptiroqAllma
git@github.com:Symanty/OptiroqAllma.git
git@gitlab.com:Symanty/OptiroqAllma.git"
got=$(
  # SC2123 warns that assigning PATH is usually a typo for PATH=$PATH:x. Breaking the
  # search path IS the experiment here, and it is confined to this subshell.
  # shellcheck disable=SC2123
  PATH=/nonexistent-so-only-builtins-work
  # shellcheck source=bin/fm-repo-url-lib.sh disable=SC1091
  . "$ROOT/bin/fm-repo-url-lib.sh"
  for u in $G_URLS; do fm_repo_url_canonical "$u"; printf '\n'; done
)
want="$EXPECTED_IDENTITY
$EXPECTED_IDENTITY
$EXPECTED_IDENTITY
gitlab.com/Symanty/OptiroqAllma"
[ "$got" = "$want" ] || fail "(g) with no external command on PATH the canonicaliser changed its answers.
--- want ---
$want
--- got ---
$got"
pass "(g) the canonicaliser uses only shell builtins, so a missing binary cannot empty a host"
