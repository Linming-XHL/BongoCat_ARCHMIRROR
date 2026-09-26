#!/usr/bin/env bash
#
# Assembles the pacman repository and the Cloudflare Pages deployment directory
# from the packages kept in the release store.
#
# Usage: assemble-repo.sh [--dir public] [--store-dir packages] [--keep N]
#                         [--site-url URL] [--repo-name NAME]
#                         [--store-repo OWNER/REPO] [--store-tag TAG]
#                         [--from-dir DIR]
#
# --from-dir skips the release store and assembles from a local directory of
# packages instead, which is what a local dry run uses.
#
# Environment: STORE_REPO, STORE_TAG, KEEP_VERSIONS, SITE_URL, GPG_PRIVATE_KEY

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/gpg.sh"
source "$(dirname "${BASH_SOURCE[0]}")/store-api.sh"

out_dir=$REPO_ROOT/public
store_dir=$REPO_ROOT/packages
site_url=${SITE_URL:-}
repo_name=''
keep=${KEEP_VERSIONS:-3}
from_dir=''

while (( $# )); do
  case $1 in
    --dir)        out_dir=$2; shift 2 ;;
    --store-dir)  store_dir=$2; shift 2 ;;
    --keep)       keep=$2; shift 2 ;;
    --site-url)   site_url=$2; shift 2 ;;
    --repo-name)  repo_name=$2; shift 2 ;;
    --store-repo) STORE_REPO=$2; shift 2 ;;
    --store-tag)  STORE_TAG=$2; shift 2 ;;
    --from-dir)   from_dir=$2; store_dir=$2; shift 2 ;;
    -h|--help)    sed -n '2,10p' "$0"; exit 0 ;;
    *)            die "unknown argument: $1" ;;
  esac
done

require_cmd repo-add bsdtar sed awk sha256sum jq numfmt
[[ $keep =~ ^[0-9]+$ ]] || die "--keep expects a number, got: $keep"
(( keep >= 1 )) || die '--keep must keep at least one package, otherwise the repository would be empty'
repo_name=${repo_name:-$(pkgbuild_field pkgname)}

gpg_import_key
key_id=$(gpg_key_id)
fingerprint=$(gpg_fingerprint "$key_id")

# ---- collect the packages --------------------------------------------------
if [[ -n $from_dir ]]; then
  log "assembling from $from_dir instead of the release store"
else
  store_fetch "$store_dir"
fi
mapfile -t stored < <(ls -1 "$store_dir"/*.pkg.tar.zst 2>/dev/null || true)
(( ${#stored[@]} )) || die "no packages found in $store_dir"

[[ -n $from_dir ]] || store_prune "$keep" "$store_dir"

mapfile -t stored < <(ls -1 "$store_dir"/*.pkg.tar.zst 2>/dev/null || true)
log "publishing ${#stored[@]} package(s): $(printf '%s ' "${stored[@]##*/}")"

# ---- assemble the deployment tree -----------------------------------------
rm -rf "$out_dir"
install -d "$out_dir/x86_64"
for pkg in "${stored[@]}"; do
  install -m 644 "$pkg" "$out_dir/x86_64/"
  [[ -f $pkg.sig ]] || die "package $(basename "$pkg") has no signature"
  install -m 644 "$pkg.sig" "$out_dir/x86_64/"
done

# ---- regenerate and sign the databases ------------------------------------
log 'regenerating the repository databases'
(
  cd "$out_dir/x86_64"
  repo-add --sign --key "$key_id" "$repo_name.db.tar.gz" ./*.pkg.tar.zst
) >&2

# repo-add links <repo>.db to <repo>.db.tar.gz and so on. Cloudflare Pages is
# served from object storage without symlink support, so the aliases become real
# files: the signature stays valid because the signed bytes do not change.
(
  cd "$out_dir/x86_64"
  for alias in "$repo_name.db" "$repo_name.db.sig" \
               "$repo_name.files" "$repo_name.files.sig"; do
    [[ -L $alias ]] || continue
    cp --remove-destination "$(readlink -f "$alias")" "$alias"
  done
)

if find "$out_dir" -type l -print -quit | grep -q .; then
  die 'the deployment still contains symlinks, which Cloudflare Pages cannot serve'
fi

# ---- sanity check the database --------------------------------------------
database="$out_dir/x86_64/$repo_name.db.tar.gz"
[[ -s $database ]] || die 'repo-add produced no database'
[[ -s $database.sig ]] || die 'the database was not signed'
gpg --batch --verify "$database.sig" "$database" >/dev/null 2>&1 \
  || die 'the database signature does not verify'

declare -A entry_version=() entry_file=()
while IFS=$'\t' read -r file version; do
  entry_version[$file]=$version
  entry_file[$file]=1
done < <(db_descriptions "$database" \
  | awk '/^%FILENAME%$/ { getline; file=$0; next } /^%VERSION%$/ { getline; print file "\t" $0 }')

(( ${#entry_file[@]} )) || die 'the database has no package entries'
for file in "${!entry_file[@]}"; do
  [[ -f $out_dir/x86_64/$file ]] \
    || die "the database references $file, which is not part of the deployment"
  [[ -f $out_dir/x86_64/$file.sig ]] \
    || die "the database references $file, which has no signature"
done

latest=$(printf '%s\n' "${entry_version[@]}" | sort -V | tail -n1)

# ---- the site itself -------------------------------------------------------
gpg --batch --armor --export "$key_id" >"$out_dir/$repo_name-repo.asc" \
  || die 'cannot export the public signing key'

packages_html=''
packages_json='[]'
for file in "${!entry_file[@]}"; do
  version=${entry_version[$file]}
  size=$(stat -c%s "$out_dir/x86_64/$file")
  human=$(numfmt --to=iec-i --suffix=B --format='%.1f' "$size" 2>/dev/null || printf '%s bytes' "$size")
  sha=$(sha256sum "$out_dir/x86_64/$file" | awk '{print $1}')
  packages_html+="        <tr><td>$repo_name</td><td>$version</td><td>$human</td><td><a href=\"x86_64/$file\">$file</a><br><span class=\"fp\">sha256 $sha</span></td></tr>"$'\n'
  packages_json=$(jq -c --arg n "$repo_name" --arg v "$version" --arg f "$file" \
    --argjson s "$size" --arg sha "$sha" \
    '. + [{name: $n, version: $v, filename: $f, size: $s, sha256: $sha}]' <<<"$packages_json")
done

render() { # render <source> <destination>
  local src=$1 dst=$2
  sed -e "s|__SITE_URL__|$(sed_escape "$site_url")|g" \
      -e "s|__REPO_NAME__|$(sed_escape "$repo_name")|g" \
      -e "s|__KEY_ID__|$(sed_escape "$key_id")|g" \
      -e "s|__FINGERPRINT_COMPACT__|$(sed_escape "$fingerprint")|g" \
      -e "s|__FINGERPRINT__|$(sed_escape "$(format_fingerprint "$fingerprint")")|g" \
      -e "s|__LATEST_VERSION__|$(sed_escape "$latest")|g" \
      -e "s|__UPDATED__|$(date -u '+%Y-%m-%d %H:%M UTC')|g" \
      -e "s|__PACKAGES__|$(sed_escape "$packages_html")|g" \
      "$src" >"$dst"
}

sed_escape() { printf '%s' "$1" | sed -e 's/[&\\|]/\\&/g'; }

format_fingerprint() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | fold -w4 | paste -sd' ' -
}

render "$REPO_ROOT/repo-site/index.html" "$out_dir/index.html"
install -m 644 "$REPO_ROOT/repo-site/_headers" "$out_dir/_headers"
render "$REPO_ROOT/repo-site/_headers" "$out_dir/_headers"
render "$REPO_ROOT/repo-site/setup.sh" "$out_dir/setup.sh"
chmod 755 "$out_dir/setup.sh"
jq '.' <<<"$packages_json" >"$out_dir/packages.json"

if grep -rl '__[A-Z_]*__' "$out_dir" >/dev/null 2>&1; then
  warn "unrendered placeholders remain in: $(grep -rl '__[A-Z_]*__' "$out_dir" | tr '\n' ' ')"
fi

log "deployment tree ready at $out_dir ($(du -sh "$out_dir" | cut -f1), $latest, $(du -a "$out_dir" | wc -l) files)"

ci_append "${GITHUB_OUTPUT:-}" "public_dir=$out_dir
latest_version=$latest
fingerprint=$fingerprint"

# The workflow commits the version bump only after a successful deployment.
if [[ -w ${GITHUB_STEP_SUMMARY:-} ]]; then
  {
    printf '### Repository contents\n\n'
    printf '| Package | Version | Size | sha256 |\n| --- | --- | --- | --- |\n'
    for file in "${!entry_file[@]}"; do
      printf '| %s | %s | %s | `%s` |\n' "$repo_name" "${entry_version[$file]}" \
        "$(numfmt --to=iec-i --suffix=B --format='%.1f' "$(stat -c%s "$out_dir/x86_64/$file")" 2>/dev/null || echo "?")" \
        "$(sha256sum "$out_dir/x86_64/$file" | cut -c1-16)"
    done
    printf '\nSigning key: `%s`\n' "$fingerprint"
  } >>"$GITHUB_STEP_SUMMARY"
fi
