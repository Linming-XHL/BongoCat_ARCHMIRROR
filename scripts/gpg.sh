#!/usr/bin/env bash
# GnuPG helpers for the signing steps. Sourced by the build and repo scripts.
#
# Environment:
#   GPG_PRIVATE_KEY        armored private signing key (Actions secret)
#   GPG_PRIVATE_KEY_FILE   file holding that key, used when the key cannot be
#                          passed through the environment (for example across su)
#   GPG_PASSPHRASE         optional passphrase for that key
#   GPG_PASSPHRASE_FILE    file holding that passphrase
#   GNUPG_KEY_ID           optional explicit key id to use

# Makes the GnuPG home usable for unattended signing.
gpg_prepare() {
  require_cmd gpg
  export GNUPGHOME=${GNUPGHOME:-$HOME/.gnupg}
  install -d -m 700 "$GNUPGHOME"

  # repo-add and gpg must not try to talk to a pinentry in CI.
  if ! grep -qs '^pinentry-mode loopback' "$GNUPGHOME/gpg.conf" 2>/dev/null; then
    printf 'pinentry-mode loopback\n' >>"$GNUPGHOME/gpg.conf"
  fi

  if [[ -z ${GPG_PASSPHRASE:-} && -n ${GPG_PASSPHRASE_FILE:-} ]]; then
    [[ -r $GPG_PASSPHRASE_FILE ]] || die "cannot read GPG_PASSPHRASE_FILE"
    GPG_PASSPHRASE=$(cat "$GPG_PASSPHRASE_FILE")
  fi
  if [[ -n ${GPG_PASSPHRASE:-} ]]; then
    printf '%s' "$GPG_PASSPHRASE" >"$GNUPGHOME/passphrase"
    chmod 600 "$GNUPGHOME/passphrase"
    if ! grep -qs '^passphrase-file' "$GNUPGHOME/gpg.conf"; then
      printf 'passphrase-file %s\n' "$GNUPGHOME/passphrase" >>"$GNUPGHOME/gpg.conf"
    fi
    printf 'allow-loopback-pinentry\n' >>"$GNUPGHOME/gpg-agent.conf"
    gpgconf --kill gpg-agent >/dev/null 2>&1 || true
  fi
}

# Imports the signing key once and remembers its id for later steps.
gpg_import_key() {
  gpg_prepare

  if [[ -z ${GPG_PRIVATE_KEY:-} && -n ${GPG_PRIVATE_KEY_FILE:-} ]]; then
    [[ -r $GPG_PRIVATE_KEY_FILE ]] || die "cannot read GPG_PRIVATE_KEY_FILE"
    GPG_PRIVATE_KEY=$(cat "$GPG_PRIVATE_KEY_FILE")
  fi
  if [[ -n ${GPG_PRIVATE_KEY:-} ]]; then
    log 'importing the repository signing key'
    printf '%s\n' "$GPG_PRIVATE_KEY" | gpg --batch --quiet --import \
      || die 'cannot import the signing key'
    unset GPG_PRIVATE_KEY
  fi

  local key_id
  key_id=$(gpg_key_id)
  [[ -n $key_id ]] || die 'no secret signing key available (set GPG_PRIVATE_KEY)'

  # Fail early instead of producing packages nobody can verify.
  gpg --batch --list-secret-keys "$key_id" >/dev/null 2>&1 \
    || die "no secret key for $key_id"

  printf '%s\n' "$key_id" >"$REPO_ROOT/.gpg-key-id"
  ci_append "${GITHUB_ENV:-}" "GNUPG_KEY_ID=$key_id"
  ci_append "${GITHUB_OUTPUT:-}" \
    "key_id=$key_id
fingerprint=$(gpg_fingerprint "$key_id")"
  log "signing with key $key_id ($(gpg_fingerprint "$key_id"))"
}

gpg_key_id() {
  if [[ -n ${GNUPG_KEY_ID:-} ]]; then
    printf '%s\n' "$GNUPG_KEY_ID"
    return 0
  fi
  if [[ -n ${GPG_KEY_ID:-} ]]; then
    printf '%s\n' "$GPG_KEY_ID"
    return 0
  fi
  if [[ -s $REPO_ROOT/.gpg-key-id ]]; then
    cat "$REPO_ROOT/.gpg-key-id"
    return 0
  fi
  gpg --batch --list-secret-keys --with-colons 2>/dev/null \
    | awk -F: '/^sec:/ { print $5; exit }'
}

gpg_fingerprint() {
  gpg --batch --with-colons --fingerprint "${1:-$(gpg_key_id)}" 2>/dev/null \
    | awk -F: '/^fpr:/ { print $10; exit }'
}

gpg_sign_file() { # gpg_sign_file <file> [<signature>]
  local file=$1 signature=${2:-$1.sig}
  gpg --batch --yes --detach-sign --local-user "$(gpg_key_id)" --output "$signature" "$file"
}
