#!/usr/bin/env bash
#
# Builds and signs one package of the repository.
#
# Usage: build-package.sh <package> [--version V] [--bump-pkgrel] [--out DIR]
#
# Prints KEY=VALUE lines for $GITHUB_OUTPUT:
#   pkgname, pkgfile, sigfile, version, size, sha256
#
# Environment: GPG_PRIVATE_KEY, GPG_PASSPHRASE (optional), GNUPG_KEY_ID (optional)

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/gpg.sh"

pkgname=''
version=''
bump=false
out_dir=$REPO_ROOT/dist

while (( $# )); do
  case $1 in
    --version)      version=$2; shift 2 ;;
    --bump-pkgrel)  bump=true; shift ;;
    --out)          out_dir=$2; shift 2 ;;
    --key-file)     export GPG_PRIVATE_KEY_FILE=$2; shift 2 ;;
    --passphrase-file) export GPG_PASSPHRASE_FILE=$2; shift 2 ;;
    -h|--help)      sed -n '2,12p' "$0"; exit 0 ;;
    -*)             die "unknown argument: $1" ;;
    *)              pkgname=$1; shift ;;
  esac
done

require_cmd makepkg bsdtar awk sed stat sha256sum
(( EUID != 0 )) || die 'makepkg refuses to run as root; build as an unprivileged user'
[[ -n $pkgname ]] || die 'usage: build-package.sh <package> [--version V] [--bump-pkgrel] [--out DIR]'

pkgdir=''
for dir in $(package_dirs); do
  [[ $(package_name "$dir") == "$pkgname" ]] || continue
  pkgdir=$dir
done
[[ -n $pkgdir ]] || die "no such package: $pkgname"

if [[ -n $version || $bump == true ]]; then
  # A bump without a version applies to the version the PKGBUILD already
  # records: that is how a package which tracks its own upstream (the SDK)
  # gets a new pkgrel when a release is republished.
  args=("$pkgname" "${version:-$(pkgbuild_field pkgver "$pkgdir/PKGBUILD")}")
  $bump && args+=(--bump-pkgrel)
  "$REPO_ROOT/scripts/set-pkgver.sh" "${args[@]}" >/dev/null
fi

pkgver=$(pkgbuild_field pkgver "$pkgdir/PKGBUILD")
pkgrel=$(pkgbuild_field pkgrel "$pkgdir/PKGBUILD")
full_version="$pkgver-$pkgrel"

gpg_import_key

log "building $pkgname $full_version"
# makepkg records the packager in .PKGINFO and falls back to a placeholder when
# the environment says nothing about it, which is the case on CI runners.
export PACKAGER=${PACKAGER:-"${GITHUB_REPOSITORY:-BongoCat-X arch repository} (automated build)"}
# The dependencies are expected to be installed already (the workflow installs
# the PKGBUILD's makedepends and depends up front), so makepkg needs no sudo.
( cd "$pkgdir" && makepkg --noconfirm --force --clean --noprogressbar )

pkgfile="$pkgdir/$pkgname-$full_version-x86_64.pkg.tar.zst"
if [[ ! -f $pkgfile ]]; then
  # Fall back to the most recent archive matching the PKGBUILD's name.
  mapfile -t candidates < <(ls -1t "$pkgdir/$pkgname-"*-x86_64.pkg.tar.zst 2>/dev/null || true)
  (( ${#candidates[@]} )) || die "makepkg produced no package for $full_version"
  pkgfile=${candidates[0]}
  warn "expected $pkgname-$full_version-x86_64.pkg.tar.zst, verifying $pkgfile instead"
fi

# ---- verification ----------------------------------------------------------
size=$(stat -c%s "$pkgfile")
readonly pages_file_limit=$((25 * 1024 * 1024))
if (( size >= pages_file_limit )); then
  die "$(basename "$pkgfile") is $((size / 1024 / 1024)) MiB, which exceeds the 25 MiB per-file limit of Cloudflare Pages"
fi

# Grep the listing through a file: piping into "grep -q" trips over SIGPIPE
# under pipefail, because grep exits as soon as it matches.
contents_list=$(mktemp)
trap 'rm -f "$contents_list"' EXIT
bsdtar -tf "$pkgfile" >"$contents_list" || die "cannot list the contents of $pkgfile"

# Each package declares what has to be inside it, next to the PKGBUILD that
# builds it, instead of this script carrying a list per package that drifts.
verify_file="$pkgdir/verify-files"
[[ -f $verify_file ]] || die "missing $verify_file (the paths every build of $pkgname must contain)"
mapfile -t required < "$verify_file"
(( ${#required[@]} )) || die "$verify_file lists no paths"
for path in "${required[@]}"; do
  [[ -n $path && $path != \#* ]] || continue
  grep -qxF "$path" "$contents_list" || die "package is missing $path"
done

metadata=$(bsdtar -xOf "$pkgfile" .PKGINFO)
grep -qx "pkgname = $pkgname" <<<"$metadata" || die 'package metadata has an unexpected pkgname'
grep -qx "pkgver = $full_version" <<<"$metadata" \
  || die "package metadata does not record version $full_version"

# ---- signing ---------------------------------------------------------------
sigfile="$pkgfile.sig"
rm -f "$sigfile"
gpg_sign_file "$pkgfile" "$sigfile"
gpg --batch --verify "$sigfile" "$pkgfile" >/dev/null 2>&1 \
  || die 'the freshly created package signature does not verify'

install -d "$out_dir"
install -m 644 "$pkgfile" "$out_dir/"
install -m 644 "$sigfile" "$out_dir/"
pkgfile="$out_dir/$(basename "$pkgfile")"
sigfile="$pkgfile.sig"

sha=$(sha256sum "$pkgfile" | awk '{print $1}')
log "built $(basename "$pkgfile"): $((size / 1024)) KiB, sha256 $sha"

# The workflow reads this file, which also works when the build runs as a user
# that cannot write the runner's command files.
cat >"$out_dir/build-info.env" <<EOF
pkgname=$pkgname
pkgfile=$(basename "$pkgfile")
sigfile=$(basename "$sigfile")
version=$full_version
size=$size
sha256=$sha
EOF
ci_append "${GITHUB_OUTPUT:-}" "$(cat "$out_dir/build-info.env")"
