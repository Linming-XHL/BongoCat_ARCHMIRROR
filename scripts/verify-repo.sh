#!/usr/bin/env bash
#
# Checks a generated deployment tree the way a client would.
#
# With root rights it builds a throwaway pacman configuration and keyring,
# syncs the repository and downloads the package, so the database and package
# signatures are verified by pacman itself. Without root it still verifies both
# signatures with GnuPG and reports what it skipped.
#
# Usage: verify-repo.sh [--dir public] [--repo-name NAME] [--pkgname NAME]

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

dir=$REPO_ROOT/public
repo_name=''
pkgname=''

while (( $# )); do
  case $1 in
    --dir)       dir=$2; shift 2 ;;
    --repo-name) repo_name=$2; shift 2 ;;
    --pkgname)   pkgname=$2; shift 2 ;;
    -h|--help)   sed -n '2,10p' "$0"; exit 0 ;;
    *)           die "unknown argument: $1" ;;
  esac
done

require_cmd gpg sha256sum
repo_name=${repo_name:-$(pkgbuild_field pkgname)}
pkgname=${pkgname:-$repo_name}
arch=$(pkgbuild_field arch)
[[ $arch == *x86_64* ]] && arch=x86_64

repo_dir="$dir/$arch"
database="$repo_dir/$repo_name.db.tar.gz"
[[ -s $database ]] || die "no repository database at $database"
[[ -s $database.sig ]] || die "the database $database is not signed"

# ---- signature level checks (always available) -----------------------------
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GNUPGHOME="$work/gnupg"
install -d -m 700 "$GNUPGHOME"
gpg --batch --quiet --import "$dir/$repo_name-repo.asc" \
  || die 'the published public key cannot be imported'

gpg --batch --verify "$database.sig" "$database" \
  || die 'the database signature does not verify with the published key'
log 'database signature verified'

packages=0
for pkg in "$repo_dir"/*.pkg.tar.zst; do
  [[ -f $pkg ]] || continue
  [[ -f $pkg.sig ]] || die "$(basename "$pkg") has no detached signature"
  gpg --batch --verify "$pkg.sig" "$pkg" \
    || die "$(basename "$pkg") signature does not verify with the published key"
  packages=$(( packages + 1 ))
done
(( packages > 0 )) || die "no packages found in $repo_dir"
log "$packages package signature(s) verified"

# Every file the database advertises has to be reachable from the server URL.
while read -r file; do
  [[ -f $repo_dir/$file ]] || die "the database advertises $file, which is missing"
  [[ -f $repo_dir/$file.sig ]] || die "the database advertises $file, which has no signature"
done < <(db_filenames "$database")
log 'every entry in the database resolves to a signed package'

# ---- pacman level checks (root only) --------------------------------------
if (( EUID != 0 )); then
  warn 'skipping the pacman sync check: it needs root (run this script with sudo for the full test)'
  exit 0
fi

require_cmd pacman pacman-key
install -d "$work"/{db,cache,gnupg-pacman,hooks} "$work"/cache/pkg
cat >"$work/pacman.conf" <<EOF
[options]
RootDir = /
DBPath = $work/db
CacheDir = $work/cache/pkg
GPGDir = $work/gnupg-pacman
LogFile = $work/pacman.log
HookDir = $work/hooks
Architecture = $arch
SigLevel = Required DatabaseOptional

[$repo_name]
Server = file://$repo_dir
EOF

pacman-key --gpgdir "$work/gnupg-pacman" --init >/dev/null 2>&1
fingerprint=$(gpg --batch --with-colons --import-options show-only \
  --import "$dir/$repo_name-repo.asc" 2>/dev/null | awk -F: '/^fpr:/ { print $10; exit }')
pacman-key --gpgdir "$work/gnupg-pacman" --add "$dir/$repo_name-repo.asc" >/dev/null
pacman-key --gpgdir "$work/gnupg-pacman" --lsign-key "$fingerprint" >/dev/null

cleanup_pacman() { rm -rf "$work"; }
trap cleanup_pacman EXIT

log 'syncing the repository with a throwaway pacman configuration'
pacman -Sy --config "$work/pacman.conf" --noconfirm || die 'pacman could not sync the repository'
pacman -Si "$pkgname" --config "$work/pacman.conf" >/dev/null \
  || die "the synced database does not describe $pkgname"

# -dd keeps dependency resolution out of a machine that is not the build host;
# the download still verifies the package signature, which is the point here.
log 'downloading the package through pacman to check its signature'
pacman -Sddw "$pkgname" --config "$work/pacman.conf" --noconfirm \
  || die 'pacman refused the package: signature or metadata problem'

log 'pacman synced the repository, read the metadata and verified the package signature'
