#!/usr/bin/env bash
# Talks to the rolling GitHub release that keeps the built packages. That
# release is the durable store the Cloudflare Pages deployment is assembled
# from, so a lost or failed deployment can always be rebuilt from it.
#
# Environment:
#   STORE_REPO   owner/name of the repository holding the release
#   STORE_TAG    release tag acting as the store (default: arch-repo-store)
#   GH_TOKEN / GITHUB_TOKEN   token with contents: write
#
# Sourced by the pipeline scripts; not meant to be run directly.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

STORE_REPO=${STORE_REPO:-}
STORE_TAG=${STORE_TAG:-arch-repo-store}

_store_api() { # _store_api <curl args...>
  [[ -n $STORE_REPO ]] || die 'STORE_REPO is not set'
  gh_auth_args
  curl -fsSL "${GH_AUTH_ARGS[@]}" -H 'Accept: application/vnd.github+json' "$@"
}

# The store release is created on first use and deliberately marked as a
# prerelease, so it never becomes the repository's "latest" release.
store_release_id() {
  local id
  id=$(_store_api "$API_ROOT/repos/$STORE_REPO/releases/tags/$STORE_TAG" 2>/dev/null \
    | jq -r '.id // empty') || true
  if [[ -z $id ]]; then
    log "creating release store $STORE_TAG in $STORE_REPO"
    local payload
    payload=$(jq -n --arg tag "$STORE_TAG" \
      '{tag_name: $tag, name: "Arch package store", prerelease: true, make_latest: "false",
        body: "Rolling store of the signed pacman packages. The repository itself is served by Cloudflare Pages; these assets are the durable copy the site is rebuilt from."}')
    id=$(_store_api -X POST -H 'Content-Type: application/json' -d "$payload" \
      "$API_ROOT/repos/$STORE_REPO/releases" | jq -r '.id // empty')
    [[ -n $id ]] || die "cannot create release store $STORE_TAG"
  fi
  printf '%s\n' "$id"
}

# store_assets: "id<TAB>name" for every asset in the store.
store_assets() {
  local id
  id=$(store_release_id)
  _store_api "$API_ROOT/repos/$STORE_REPO/releases/$id/assets?per_page=100" \
    | jq -r '.[] | [.id, .name] | @tsv'
}

# store_packages: "id<TAB>name<TAB>pkgver-pkgrel" for package archives.
store_packages() {
  local id name version
  while IFS=$'\t' read -r id name; do
    version=$(store_package_version "$name") || continue
    printf '%s\t%s\t%s\n' "$id" "$name" "$version"
  done < <(store_assets | grep -E '\.pkg\.tar\.' || true)
}

# store_package_version <filename>: "bongocat-1.13.1-1-x86_64.pkg.tar.zst"
# becomes "1.13.1-1"; fails for anything that does not look like a package.
store_package_version() {
  local name=$1 version
  version=$(sed -E 's/^[^-]+-(.+)-\S+\.pkg\.tar\.[a-z]+$/\1/' <<<"$name")
  [[ $version != "$name" ]] || return 1
  printf '%s\n' "$version"
}

# store_latest_version: newest "pkgver-pkgrel" in the store, empty when unused.
store_latest_version() {
  local _ name version newest=''
  while IFS=$'\t' read -r _ name version; do
    if [[ -z $newest ]] || version_gt "$version" "$newest"; then
      newest=$version
    fi
  done < <(store_packages)
  printf '%s\n' "$newest"
}

store_asset_id() { # store_asset_id <name>
  local id name
  while IFS=$'\t' read -r id name; do
    if [[ $name == "$1" ]]; then printf '%s\n' "$id"; return 0; fi
  done < <(store_assets)
  return 1
}

store_delete_asset() { # store_delete_asset <id>
  gh_auth_args
  curl -fsSL -X DELETE "${GH_AUTH_ARGS[@]}" -H 'Accept: application/vnd.github+json' \
    "$API_ROOT/repos/$STORE_REPO/releases/assets/$1" >/dev/null
}

# store_upload <file>: uploads a file, replacing an asset of the same name.
store_upload() {
  local file=$1 name release_id id
  [[ -f $file ]] || die "cannot upload missing file: $file"
  name=$(basename "$file")

  if id=$(store_asset_id "$name"); then
    warn "$name is already stored, replacing it"
    store_delete_asset "$id"
  fi

  release_id=$(store_release_id)
  gh_auth_args
  # Asset uploads live on uploads.github.com rather than the API host.
  curl -fsSL -X POST "${GH_AUTH_ARGS[@]}" \
    -H 'Content-Type: application/octet-stream' \
    --data-binary "@$file" \
    "https://uploads.github.com/repos/$STORE_REPO/releases/$release_id/assets?name=$name" \
    >/dev/null
  log "stored $name"
}

# store_fetch <directory>: downloads every asset of the store.
store_fetch() {
  local dest=$1 id name url location
  install -d "$dest"
  while IFS=$'\t' read -r id name; do
    url="$API_ROOT/repos/$STORE_REPO/releases/assets/$id"
    gh_auth_args
    # The API answers with a redirect to signed storage and the token must not
    # be forwarded there, so the redirect is followed by hand.
    location=$(curl -fsSL -D - -o /dev/null "${GH_AUTH_ARGS[@]}" \
      -H 'Accept: application/octet-stream' "$url" 2>/dev/null \
      | tr -d '\r' | awk 'tolower($1) == "location:" { print $2 }') || true
    if [[ -n $location ]]; then
      curl -fsSL --retry 3 -o "$dest/$name" "$location"
    else
      # Public repositories can always be read through the download URL.
      curl -fsSL --retry 3 -o "$dest/$name" \
        "https://github.com/$STORE_REPO/releases/download/$STORE_TAG/$name"
    fi
    log "fetched $name"
  done < <(store_assets)
}

# store_prune <keep> <directory>: drops everything but the newest <keep>
# packages from the release store and from <directory>.
store_prune() {
  local keep=$1 dest=$2 newest=()
  local id name version sig_id

  while IFS=$'\t' read -r id name version; do
    newest+=("$version"$'\t'"$id"$'\t'"$name")
  done < <(store_packages)

  (( ${#newest[@]} > keep )) || return 0

  local index=0
  while IFS=$'\t' read -r version id name; do
    (( index++ )) || true
    (( index <= keep )) && continue
    log "pruning $name (keeping the newest $keep packages)"
    store_delete_asset "$id"
    rm -f "$dest/$name" "$dest/$name.sig"
    # The detached signature is a separate asset and would linger otherwise.
    if sig_id=$(store_asset_id "$name.sig"); then
      store_delete_asset "$sig_id"
    fi
  done < <(printf '%s\n' "${newest[@]}" | sort -t$'\t' -k1,1V -r)
}
