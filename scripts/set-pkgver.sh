#!/usr/bin/env bash
#
# Sets a package to a given upstream version and regenerates its .SRCINFO.
#
# Usage: set-pkgver.sh <package> <version> [--bump-pkgrel | --pkgrel N]
#        set-pkgver.sh <version> [--bump-pkgrel | --pkgrel N]
#
# With one version and no package name, every published package is updated, which
# is what the deployment step needs: they track the same upstream release.
#
# A new version resets pkgrel to 1; --bump-pkgrel increments it for the version
# that is already recorded, which is what a forced rebuild of the same upstream
# release needs; --pkgrel sets it outright, which is how a recovered deployment
# records the version it just published.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

version=''
pkgname_arg=''
bump=false
explicit_rel=''

positional=()
while (( $# )); do
  case $1 in
    --bump-pkgrel) bump=true; shift ;;
    --pkgrel)      explicit_rel=$2; shift 2 ;;
    -h|--help)     sed -n '2,13p' "$0"; exit 0 ;;
    -*)            die "unknown argument: $1" ;;
    *)             positional+=("$1"); shift ;;
  esac
done

if (( ${#positional[@]} == 1 )); then
  version=${positional[0]}
elif (( ${#positional[@]} == 2 )); then
  pkgname_arg=${positional[0]}
  version=${positional[1]}
else
  die 'usage: set-pkgver.sh [<package>] <version> [--bump-pkgrel | --pkgrel N]'
fi

[[ -n $version ]] || die 'no version given'
version=$(to_pkgver "$version")
[[ -z $explicit_rel || $explicit_rel =~ ^[0-9]+$ ]] || die "--pkgrel expects a number, got: $explicit_rel"

# makepkg is what regenerates .SRCINFO and it refuses to run as root, so refuse
# here as well rather than leaving the PKGBUILD and .SRCINFO out of step.
if (( EUID == 0 )) && command -v makepkg >/dev/null 2>&1; then
  die 'run this as an unprivileged user: makepkg, which refreshes .SRCINFO, refuses to run as root'
fi

if [[ -n $pkgname_arg ]]; then
  targets=()
  for dir in $(package_dirs); do
    [[ $(package_name "$dir") == "$pkgname_arg" ]] || continue
    targets+=("$dir")
  done
  (( ${#targets[@]} )) || die "no such package: $pkgname_arg"
else
  mapfile -t targets < <(package_dirs)
  (( ${#targets[@]} )) || die 'packages/ holds no PKGBUILD'
fi

last=''
for dir in "${targets[@]}"; do
  pkgbuild="$dir/PKGBUILD"
  pkgname=$(package_name "$dir")
  current_version=$(pkgbuild_field pkgver "$pkgbuild")
  current_rel=$(pkgbuild_field pkgrel "$pkgbuild")
  new_rel=$current_rel
  # Numeric on purpose: (( changed )) treats a non-empty string as a variable
  # name, so "true" would be evaluated as the unset variable $true.
  changed=0

  if [[ -n $explicit_rel ]]; then
    new_rel=$explicit_rel
    sed -i -e "s/^pkgver=.*/pkgver=$version/" -e "s/^pkgrel=.*/pkgrel=$new_rel/" "$pkgbuild"
    changed=1
    log "$pkgname: pkgver/pkgrel ${current_version}-${current_rel} -> ${version}-${new_rel}"
  elif [[ $version != "$current_version" ]]; then
    new_rel=1
    sed -i -e "s/^pkgver=.*/pkgver=$version/" -e "s/^pkgrel=.*/pkgrel=$new_rel/" "$pkgbuild"
    changed=1
    log "$pkgname: pkgver ${current_version}-${current_rel} -> ${version}-${new_rel}"
  elif $bump; then
    new_rel=$(( current_rel + 1 ))
    sed -i "s/^pkgrel=.*/pkgrel=$new_rel/" "$pkgbuild"
    changed=1
    log "$pkgname: pkgrel ${current_rel} -> ${new_rel} for ${version}"
  else
    log "$pkgname already at ${version}-${new_rel}"
  fi

  # .SRCINFO is generated from the PKGBUILD, so it has to move along with it.
  # It lives next to the PKGBUILD, because makepkg --printsrcinfo reads the
  # PKGBUILD from the current directory.
  if command -v makepkg >/dev/null 2>&1; then
    ( cd "$dir" && makepkg --printsrcinfo > .SRCINFO )
    (( changed )) && log "$pkgname: refreshed .SRCINFO"
  else
    warn "$pkgname: .SRCINFO was not refreshed: makepkg is only available on Arch Linux"
  fi

  last="$pkgname-$version-$new_rel"
done

printf '%s\n' "$last"