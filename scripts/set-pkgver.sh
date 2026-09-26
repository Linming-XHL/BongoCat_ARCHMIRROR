#!/usr/bin/env bash
# Sets the PKGBUILD to a given upstream version and regenerates .SRCINFO.
#
# Usage: set-pkgver.sh <version> [--bump-pkgrel | --pkgrel N]
#
# A new version resets pkgrel to 1; --bump-pkgrel increments it for the version
# that is already recorded, which is what a forced rebuild of the same upstream
# release needs; --pkgrel sets it outright, which is how a recovered deployment
# records the version it just published.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

version=''
bump=false
explicit_rel=''

while (( $# )); do
  case $1 in
    --bump-pkgrel) bump=true; shift ;;
    --pkgrel)      explicit_rel=$2; shift 2 ;;
    -h|--help)     sed -n '2,9p' "$0"; exit 0 ;;
    -*)            die "unknown argument: $1" ;;
    *)             version=$1; shift ;;
  esac
done

[[ -n $version ]] || die 'usage: set-pkgver.sh <version> [--bump-pkgrel | --pkgrel N]'
version=$(to_pkgver "$version")
[[ -z $explicit_rel || $explicit_rel =~ ^[0-9]+$ ]] || die "--pkgrel expects a number, got: $explicit_rel"

# makepkg is what regenerates .SRCINFO and it refuses to run as root, so refuse
# here as well rather than leaving the PKGBUILD and .SRCINFO out of step.
if (( EUID == 0 )) && command -v makepkg >/dev/null 2>&1; then
  die 'run this as an unprivileged user: makepkg, which refreshes .SRCINFO, refuses to run as root'
fi

pkgbuild="$REPO_ROOT/PKGBUILD"
current_version=$(pkgbuild_field pkgver "$pkgbuild")
current_rel=$(pkgbuild_field pkgrel "$pkgbuild")
new_rel=$current_rel

if [[ -n $explicit_rel ]]; then
  new_rel=$explicit_rel
  sed -i -e "s/^pkgver=.*/pkgver=$version/" -e "s/^pkgrel=.*/pkgrel=$new_rel/" "$pkgbuild"
  log "pkgver/pkgrel ${current_version}-${current_rel} -> ${version}-${new_rel}"
elif [[ $version != "$current_version" ]]; then
  sed -i "s/^pkgver=.*/pkgver=$version/" "$pkgbuild"
  new_rel=1
  sed -i "s/^pkgrel=.*/pkgrel=$new_rel/" "$pkgbuild"
  log "pkgver ${current_version}-${current_rel} -> ${version}-${new_rel}"
elif $bump; then
  new_rel=$(( current_rel + 1 ))
  sed -i "s/^pkgrel=.*/pkgrel=$new_rel/" "$pkgbuild"
  log "pkgrel ${current_rel} -> ${new_rel} for ${version}"
else
  log "PKGBUILD already at ${version}-${new_rel}"
fi

# .SRCINFO is generated from the PKGBUILD, so it has to move along with it.
if command -v makepkg >/dev/null 2>&1; then
  ( cd "$REPO_ROOT" && makepkg --printsrcinfo > .SRCINFO )
  log 'refreshed .SRCINFO'
else
  warn '.SRCINFO was not refreshed: makepkg is only available on Arch Linux'
fi

printf '%s-%s\n' "$version" "$new_rel"
