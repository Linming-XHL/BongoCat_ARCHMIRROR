#!/usr/bin/env bash
#
# Uploads built artefacts into the rolling release store and prunes packages
# that fell out of the retention window.
#
# Usage: publish-store.sh [--store-repo OWNER/REPO] [--store-tag TAG]
#                         [--prune N] [--dir DIR] FILE...
#
# Environment: GH_TOKEN or GITHUB_TOKEN

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/store-api.sh"

prune=''
store_dir=''
files=()

while (( $# )); do
  case $1 in
    --store-repo) STORE_REPO=$2; shift 2 ;;
    --store-tag)  STORE_TAG=$2; shift 2 ;;
    --prune)      prune=$2; shift 2 ;;
    --dir)        store_dir=$2; shift 2 ;;
    -h|--help)    sed -n '2,10p' "$0"; exit 0 ;;
    -*)           die "unknown argument: $1" ;;
    *)            files+=("$1"); shift ;;
  esac
done

[[ -n $STORE_REPO ]] || die 'STORE_REPO is not set (pass --store-repo)'
(( ${#files[@]} )) || die 'nothing to upload'
require_cmd curl jq

for file in "${files[@]}"; do
  store_upload "$file"
done

if [[ -n $prune ]]; then
  store_prune "$prune" "${store_dir:-.}"
fi

if [[ -w ${GITHUB_STEP_SUMMARY:-} ]]; then
  {
    printf '### Release store\n\n'
    while IFS=$'\t' read -r _ name version; do
      printf -- '- `%s` (%s)\n' "$name" "$version"
    done < <(store_packages)
  } >>"$GITHUB_STEP_SUMMARY"
fi
