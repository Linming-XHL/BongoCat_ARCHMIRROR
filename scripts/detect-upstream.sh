#!/usr/bin/env bash
#
# Resolves the newest upstream release and decides what the pipeline has to do.
# Writes KEY=VALUE lines to stdout, ready for $GITHUB_OUTPUT.
#
#   version       upstream version in pkgver form
#   tag           upstream release tag
#   commit        commit the upstream tag points at
#   source_url    URL of the release source archive
#   build         "true" when the package has to be rebuilt
#   bump          "true" when only pkgrel has to move
#   deploy        "true" when the Cloudflare Pages deployment has to be refreshed
#   reason        human readable explanation of the decision
#
# The version comparison is against the -bin package, which is the one that
# follows upstream releases; the SDK package is pinned to the SDK revision and
# does not change when upstream does.
#
# Usage: detect-upstream.sh [--repo OWNER/REPO] [--tag TAG] [--force]
#                           [--store-repo OWNER/REPO] [--store-tag TAG]
#                           [--repo-name NAME] [--site-url URL]
#                           [--package NAME]

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/store-api.sh"

upstream_repo=''
requested_tag=''
site_url=''
force=false
# Overridden by PRIMARY_PACKAGE from repo.conf below, so the package that
# tracks upstream releases is named in one place.
package=''

while (( $# )); do
  case $1 in
    --repo)        upstream_repo=$2; shift 2 ;;
    --tag)         requested_tag=$2; shift 2 ;;
    --store-repo)  STORE_REPO=$2; shift 2 ;;
    --store-tag)   STORE_TAG=$2; shift 2 ;;
    --repo-name)   repo_name=$2; shift 2 ;;
    --site-url)    site_url=$2; shift 2 ;;
    --package)     package=$2; shift 2 ;;
    --force)       force=true; shift ;;
    -h|--help)     sed -n '2,19p' "$0"; exit 0 ;;
    *)             die "unknown argument: $1" ;;
  esac
done

require_cmd curl jq tar sed
# shellcheck disable=SC1091
source "$REPO_ROOT/repo.conf"
[[ -n $repo_name ]] || die 'repo.conf does not set repo_name'
upstream_repo=${upstream_repo:-$UPSTREAM_REPO}
[[ -n $upstream_repo ]] || die 'no upstream repository: pass --repo or set UPSTREAM_REPO in repo.conf'
package=${package:-$PRIMARY_PACKAGE}
[[ -n $package ]] || die 'repo.conf does not set PRIMARY_PACKAGE, and --package was not given'

# Every package the pipeline builds. A package that cannot be found here is an
# error rather than a silently skipped build, because the deployment would then
# drop it from the repository.
for name in "${PUBLISHED_PACKAGES[@]}"; do
  found=''
  for dir in $(package_dirs); do
    [[ $(package_name "$dir") == "$name" ]] && found=$dir && break
  done
  [[ -n $found ]] || die "repo.conf lists $name in PUBLISHED_PACKAGES, but packages/ has no such package"
done

# The package whose version tracks upstream releases, located by name so the
# order of directories in packages/ does not matter.
pkgbuild=''
for dir in $(package_dirs); do
  [[ $(package_name "$dir") == "$package" ]] || continue
  pkgbuild=$dir/PKGBUILD
done
[[ -n $pkgbuild ]] || die "no such package: $package"
current_pkgver=$(pkgbuild_field pkgver "$pkgbuild")
current_pkgrel=$(pkgbuild_field pkgrel "$pkgbuild")

# ---- upstream release ------------------------------------------------------
gh_auth_args
if [[ -n $requested_tag ]]; then
  tag=$requested_tag
else
  release=$(curl -fsSL "${GH_AUTH_ARGS[@]}" \
    "$API_ROOT/repos/$upstream_repo/releases/latest") \
    || die "cannot read the latest release of $upstream_repo"
  tag=$(jq -r '.tag_name // empty' <<<"$release")
  [[ -n $tag ]] || die "the latest release of $upstream_repo has no tag"
fi

version=$(to_pkgver "$tag")
commit=$(curl -fsSL "${GH_AUTH_ARGS[@]}" \
  "$API_ROOT/repos/$upstream_repo/commits/$tag" | jq -r '.sha // empty') \
  || die "cannot resolve the commit of $tag"
[[ ${#commit} == 40 ]] || die "unexpected commit id for ${tag}: ${commit}"
source_url="https://github.com/$upstream_repo/archive/refs/tags/$tag.tar.gz"

# ---- what has to happen ----------------------------------------------------
build=false
bump=false
reason="upstream $tag is already packaged as ${current_pkgver}-${current_pkgrel}"
if [[ $version != "$current_pkgver" ]]; then
  build=true
  if version_gt "$version" "$current_pkgver"; then
    reason="upstream $tag is newer than the packaged $current_pkgver"
  else
    reason="$tag was requested explicitly and differs from the packaged $current_pkgver"
  fi
fi
if $force; then
  build=true
  # Rebuilding a version that is already packaged needs a new pkgrel, otherwise
  # the repository would keep serving the old archive under the same name.
  [[ $version == "$current_pkgver" ]] && bump=true
  reason="forced rebuild of $tag"
fi

# The SDK package does not track upstream releases, so a change to its own
# source (a new pinned Cubism revision) or to its PKGBUILD (a packaging fix,
# such as taking the Linux Core instead of the HarmonyOS one) is invisible to
# the version comparison above. Compare its recorded pkgrel against the PKGBUILD
# to notice that the packaged files no longer match what is being served.
if ! $build && [[ -n $STORE_REPO ]]; then
  for name in "${PUBLISHED_PACKAGES[@]}"; do
    [[ $name == "$package" ]] && continue
    local_pkgdir=''
    for dir in $(package_dirs); do
      [[ $(package_name "$dir") == "$name" ]] && local_pkgdir=$dir && break
    done
    [[ -n $local_pkgdir ]] || continue
    local_rel=$(pkgbuild_field pkgrel "$local_pkgdir/PKGBUILD")
    local_ver=$(pkgbuild_field pkgver "$local_pkgdir/PKGBUILD")
    served=$(store_served_pkgrel "$name" "$local_ver" 2>/dev/null || true)
    # bump deliberately stays false: the build step already moves a
    # non-primary package's pkgrel on every build, and bumping the primary
    # package here would advance the app's version for a change that did not
    # touch it.
    if [[ -z $served ]]; then
      build=true
      reason="$name $local_ver is published but the store holds no such version; rebuilding"
    elif [[ $served != "$local_rel" ]]; then
      build=true
      reason="$name is served as $local_ver-$served while the PKGBUILD records $local_ver-$local_rel; rebuilding"
    fi
  done
fi

# The site is refreshed whenever it serves a different package set than the store
# holds. That way an interrupted deployment heals on the next scheduled run
# instead of leaving the repository stale until someone notices.
deploy=$build
if ! $build && [[ -n $site_url && -n $STORE_REPO ]]; then
  # The store and the site both hold several packages, so they are compared by
  # their package files: a name list is enough to notice a package that is
  # missing on either side without mistaking one package for another.
  store_set=$(store_package_names | sort | tr '\n' ' ')
  site_set=''
  db=$(mktemp) || die 'cannot create a temporary file'
  if curl -fsSL --max-time 60 "$site_url/x86_64/$repo_name.db.tar.gz" -o "$db" 2>/dev/null; then
    site_set=$(db_package_names "$db" | sort | tr '\n' ' ')
  fi
  rm -f "$db"
  if [[ -n $store_set && $site_set != "$store_set" ]]; then
    deploy=true
    reason="the store holds [${store_set% }] while the site serves [${site_set% }]; republishing"
  fi
fi

cat <<EOF
version=$version
tag=$tag
commit=$commit
source_url=$source_url
build=$build
bump=$bump
deploy=$deploy
reason=$reason
EOF
