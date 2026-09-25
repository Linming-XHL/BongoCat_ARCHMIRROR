#!/usr/bin/env bash
# Shared helpers for the arch-repo tooling. Sourced by the other scripts.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
API_ROOT='https://api.github.com'

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
  done
}

# pkgbuild_field <field> [pkgbuild]: reads a plain assignment without executing
# the rest of the PKGBUILD.
pkgbuild_field() {
  local field=$1 file=${2:-$REPO_ROOT/PKGBUILD}
  [[ -f $file ]] || die "no such PKGBUILD: $file"
  sed -n "s/^${field}=\(.*\)\$/\1/p" "$file" | head -n1 | sed "s/^['\"]//; s/['\"]\$//"
}

# Fills GH_AUTH_ARGS with the authentication header for the GitHub API, if a
# token is available in the environment.
gh_auth_args() {
  GH_AUTH_ARGS=()
  local token=${GH_TOKEN:-${GITHUB_TOKEN:-}}
  if [[ -n $token ]]; then
    GH_AUTH_ARGS=(-H "Authorization: Bearer $token")
  fi
  return 0
}

# version_gt <a> <b>: Arch-ish version comparison that also works on the plain
# Ubuntu runners, where vercmp (pacman) does not exist.
version_gt() {
  [[ $1 != "$2" ]] || return 1
  [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1) == "$1" ]]
}

# Normalises an upstream tag or version into a valid pkgver.
to_pkgver() {
  local raw=${1#v}
  raw=${raw//-/_}
  [[ $raw =~ ^[0-9][0-9A-Za-z._+]*$ ]] || die "not a usable pkgver: $1"
  printf '%s\n' "$raw"
}

# archive_tool: bsdtar where it exists (Arch), GNU tar everywhere else, since
# the runners do not ship bsdtar by default.
archive_tool() {
  if command -v bsdtar >/dev/null 2>&1; then
    printf 'bsdtar\n'
  else
    printf 'tar\n'
  fi
}

# db_descriptions <database>: prints the concatenated desc entries of a pacman
# repository database. Members are selected by listing them first, because the
# "--wildcards" switch that GNU tar needs for patterns does not exist in bsdtar.
db_descriptions() {
  local database=$1 tool member members=()
  tool=$(archive_tool)
  while IFS= read -r member; do
    [[ -n $member ]] && members+=("$member")
  done < <("$tool" -tf "$database" 2>/dev/null | grep '/desc$' || true)
  (( ${#members[@]} )) || return 1
  "$tool" -xOf "$database" "${members[@]}"
}

# db_filenames <database>: the package archives a database advertises.
db_filenames() {
  db_descriptions "$1" | awk '/^%FILENAME%$/ { getline; print }'
}

# db_versions <database>: the versions a database advertises.
db_versions() {
  db_descriptions "$1" | awk '/^%VERSION%$/ { getline; print }'
}
