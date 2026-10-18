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

# store_packages: "id<TAB>name<TAB>pkgver-pkgrel<TAB>pkgname" for package
# archives. The package name is what store_prune groups its retention window
# by, and every published name contains dashes ("bongocat-x-bin",
# "live2d-sdk-nonfree"), so it is matched against the names this repository
# actually publishes rather than split on a dash.
store_packages() {
  local id name version pkgname
  while IFS=$'\t' read -r id name; do
    version=$(store_package_version "$name") || continue
    pkgname=$(store_package_name "$name") || continue
    printf '%s\t%s\t%s\t%s\n' "$id" "$name" "$version" "$pkgname"
  done < <(store_assets | grep -E '\.pkg\.tar\.(gz|zst)$' || true)
}

# store_package_name <filename>: the published package name the archive belongs
# to, matched longest-first so "bongocat-x-bin" is not confused with a prefix of
# another name. Returns nothing when the name is not one this repository
# publishes, which is how foreign assets are ignored.
store_package_name() {
  local name=$1 pkgbase candidate
  # repo.conf is sourced by the scripts that reach this point, but relying on
  # that ordering is how a caller silently stops pruning correctly, so load it
  # here when the names are not already known.
  if [[ -z ${PUBLISHED_PACKAGES[*]:-} && -f $REPO_ROOT/repo.conf ]]; then
    # shellcheck disable=SC1091
    source "$REPO_ROOT/repo.conf"
  fi
  [[ -n ${PUBLISHED_PACKAGES[*]:-} ]] || return 1
  for candidate in "${PUBLISHED_PACKAGES[@]}"; do
    if [[ $name == "$candidate"-* ]]; then
      # Prefer the longest match: a name can be a prefix of another.
      if [[ -z ${pkgbase:-} || ${#candidate} -gt ${#pkgbase} ]]; then
        pkgbase=$candidate
      fi
    fi
  done
  [[ -n ${pkgbase:-} ]] || return 1
  printf '%s\n' "$pkgbase"
}

# store_package_version <filename>: "bongocat-x-bin-2.2.0-1-x86_64.pkg.tar.zst"
# becomes "2.2.0-1". The package name is stripped from the left by matching
# against the name this repository actually publishes, because every one of them
# contains dashes ("bongocat-x-bin", "live2d-sdk-nonfree") and splitting on the
# first dash would leave a fragment behind.
store_package_version() {
  local name=$1 version
  version=$(sed -E -e 's/^.*-(x-bin|x-git|sdk-nonfree)-//' \
                   -e 's/-x[0-9_]+\.pkg\.tar\.[a-z]+$//' <<<"$name")
  [[ $version != "$name" && -n $version ]] || return 1
  printf '%s\n' "$version"
}

# store_package_names: the published package names the store holds, one per
# line, without duplicates (a package with several versions is still one name).
store_package_names() {
  local _ _version pkgname
  while IFS=$'\t' read -r _ _name _version pkgname; do
    printf '%s\n' "$pkgname"
  done < <(store_packages) | sort -u
}

# store_served_pkgrel <pkgname> <pkgver>: the pkgrel the store is currently
# serving for that exact pkgver, or nothing when it serves no such version.
# detect-upstream.sh uses this to notice a package whose PKGBUILD changed (a
# packaging fix, or a new pinned source revision) without its version moving,
# which a version-only comparison cannot see.
store_served_pkgrel() {
  local want_name=$1 want_ver=$2 id name version pkgname rel newest=''
  while IFS=$'\t' read -r id name version pkgname; do
    [[ $pkgname == "$want_name" ]] || continue
    rel=${version##*-}
    [[ $version == "$want_ver-$rel" ]] || continue
    # The store can hold several pkgrels of the same version (the build bumps
    # one every run), and store_packages lists assets in upload order, so the
    # first match is the oldest. Answer with the largest, or detect never sees
    # the current one and rebuilds forever.
    if [[ -z $newest ]] || (( rel > newest )); then
      newest=$rel
    fi
  done < <(store_packages)
  [[ -n $newest ]] || return 1
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
# versions of each package from the release store and from <directory>.
#
# The window is per package name, not global: the repository holds packages
# with unrelated version series (the app tracks upstream 2.2.0, the SDK is
# pinned to its own 5.0.5), and keeping the newest <keep> entries across all of
# them let an older pkgrel of one package push the other package out entirely.
store_prune() {
  local keep=$1 dest=$2
  local id name version sig_id pkgname index
  local -A all=()

  # "id<TAB>name<TAB>version<TAB>pkgname" per package, grouped by package name
  # in the order they were read; store_assets comes oldest first.
  while IFS=$'\t' read -r id name version pkgname; do
    all[$pkgname]+="${id}"$'\t'"${name}"$'\t'"${version}"$'\n'
  done < <(store_packages)

  for pkgname in "${!all[@]}"; do
    index=0
    # Newest version first: store_assets comes in upload order, which is oldest
    # first, so the version column decides what is retained. The reverse has to
    # ride on the key suffix (-k3,3Vr): with -k3,3V plus a separate -r, GNU sort
    # still ordered these ascending and pruned the version just uploaded.
    while IFS=$'\t' read -r id name version; do
      (( index++ )) || true
      (( index <= keep )) && continue
      log "pruning $name (keeping the newest $keep versions of $pkgname)"
      store_delete_asset "$id"
      rm -f "$dest/$name" "$dest/$name.sig"
      # The detached signature is a separate asset and would linger otherwise.
      if sig_id=$(store_asset_id "$name.sig"); then
        store_delete_asset "$sig_id"
      fi
    done < <(printf '%s' "${all[$pkgname]}" | sort -t$'\t' -k3,3Vr)
  done
}
