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
#   deploy        "true" when the Cloudflare Pages deployment has to be refreshed
#   reason        human readable explanation of the decision
#
# Usage: detect-upstream.sh [--repo OWNER/REPO] [--tag TAG] [--force]
#                           [--store-repo OWNER/REPO] [--store-tag TAG]
#                           [--repo-name NAME] [--site-url URL]

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/store-api.sh"

upstream_repo='vladelaina/BongoCat'
requested_tag=''
site_url=''
force=false

while (( $# )); do
  case $1 in
    --repo)        upstream_repo=$2; shift 2 ;;
    --tag)         requested_tag=$2; shift 2 ;;
    --store-repo)  STORE_REPO=$2; shift 2 ;;
    --store-tag)   STORE_TAG=$2; shift 2 ;;
    --repo-name)   repo_name=$2; shift 2 ;;
    --site-url)    site_url=$2; shift 2 ;;
    --force)       force=true; shift ;;
    -h|--help)     sed -n '2,18p' "$0"; exit 0 ;;
    *)             die "unknown argument: $1" ;;
  esac
done

require_cmd curl jq tar sed
repo_name=${repo_name:-$(pkgbuild_field pkgname)}
current_pkgver=$(pkgbuild_field pkgver)
current_pkgrel=$(pkgbuild_field pkgrel)

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

# The site is refreshed whenever it serves a different package than the store
# holds. That way an interrupted deployment heals on the next scheduled run
# instead of leaving the repository stale until someone notices.
deploy=$build
if ! $build && [[ -n $site_url && -n $STORE_REPO ]]; then
  store_version=$(store_latest_version)
  site_version=''
  if [[ -n $store_version ]]; then
    db=$(mktemp) || die 'cannot create a temporary file'
    if curl -fsSL --max-time 60 "$site_url/x86_64/$repo_name.db.tar.gz" -o "$db" 2>/dev/null; then
      site_version=$(db_versions "$db" | sort -V | tail -n1)
    fi
    rm -f "$db"
    if [[ $site_version != "$store_version" ]]; then
      deploy=true
      reason="the store holds $store_version while the site serves ${site_version:-nothing}; republishing"
    fi
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
