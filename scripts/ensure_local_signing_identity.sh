#!/bin/bash

set -euo pipefail
umask 077

IDENTITY_NAME="DeepSeek Harness Local Signing"
STATE_DIR="$HOME/Library/Application Support/DeepSeek Harness/Signing/v1"
KEYCHAIN="$HOME/Library/Keychains/DeepSeekHarnessMacCompanionLocalSigning-v1.keychain-db"
PASSWORD_FILE="$STATE_DIR/keychain-password"
CERTIFICATE_FILE="$STATE_DIR/local-signing-certificate.pem"
OWNERSHIP_MARKER="$STATE_DIR/managed-keychain"
EXPECTED_MARKER="deepseek-harness-macos-local-signing-v1:$KEYCHAIN"
IDENTITY_TEMP=""

cleanup() {
  if [[ -n "$IDENTITY_TEMP" && -d "$IDENTITY_TEMP" ]]; then
    [[ ! -e "$IDENTITY_TEMP/private-key.pem" ]] || /bin/unlink "$IDENTITY_TEMP/private-key.pem"
    [[ ! -e "$IDENTITY_TEMP/identity.p12" ]] || /bin/unlink "$IDENTITY_TEMP/identity.p12"
    /bin/rmdir "$IDENTITY_TEMP" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ -n "${DSH_HARNESS_SIGNING_HOME:-}" \
    || -n "${DSH_HARNESS_SIGNING_KEYCHAIN:-}" \
    || -n "${DSH_SIGN_KEYCHAIN:-}" ]]; then
  echo "Local signing uses a fixed managed location; signing path overrides are not accepted." >&2
  exit 2
fi

# Prefer an identity that is already visible to the user's keychain search
# list. This is both the normal `codesign` lookup path and the least invasive
# option: no keychain, password file, trust setting, or access-control entry is
# created or changed. In particular, do not create a second identity merely
# because an older helper-owned keychain is incomplete.
SEARCH_LIST_OUTPUT="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null)" || {
  echo "Unable to inspect the user keychain search list; refusing to change signing keychains." >&2
  exit 1
}
SEARCH_LIST_IDENTITIES="$(
  /usr/bin/printf '%s\n' "$SEARCH_LIST_OUTPUT" \
    | /usr/bin/awk -v name="$IDENTITY_NAME" \
      '$0 ~ ("\\\"" name "\\\"") && $2 ~ /^[0-9A-F]{40}$/ { print $2 }'
)"
if [[ -n "$SEARCH_LIST_IDENTITIES" ]]; then
  SEARCH_LIST_COUNT="$(
    /usr/bin/printf '%s\n' "$SEARCH_LIST_IDENTITIES" \
      | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }'
  )"
  if [[ "$SEARCH_LIST_COUNT" -ne 1 ]]; then
    echo "Multiple $IDENTITY_NAME identities are visible; refusing to guess which one to use." >&2
    exit 1
  fi
  SEARCH_LIST_IDENTITY="$(/usr/bin/printf '%s\n' "$SEARCH_LIST_IDENTITIES" | /usr/bin/sed -n '1p')"
  echo "Reusing the existing $IDENTITY_NAME identity from the user keychain search list." >&2
  # A blank second line deliberately tells build_and_run.sh to use the normal
  # user keychain search list rather than pinning codesign to a managed file.
  /usr/bin/printf '%s\n\n' "$SEARCH_LIST_IDENTITY"
  exit 0
fi

if [[ -L "$STATE_DIR" \
    || -L "$KEYCHAIN" \
    || -L "$OWNERSHIP_MARKER" \
    || -L "$PASSWORD_FILE" \
    || -L "$CERTIFICATE_FILE" ]]; then
  echo "Refusing a symbolic-link local signing path." >&2
  exit 1
fi

/bin/mkdir -p "$STATE_DIR"
/bin/chmod 700 "$STATE_DIR"

if [[ -e "$KEYCHAIN" ]]; then
  if [[ ! -f "$OWNERSHIP_MARKER" \
      || "$(<"$OWNERSHIP_MARKER")" != "$EXPECTED_MARKER" ]]; then
    echo "Refusing to manage an existing keychain without this helper's ownership marker: $KEYCHAIN" >&2
    exit 1
  fi
elif [[ -e "$OWNERSHIP_MARKER" && "$(<"$OWNERSHIP_MARKER")" != "$EXPECTED_MARKER" ]]; then
  echo "Local signing ownership marker is invalid; remove it manually after review." >&2
  exit 1
fi

existing_identity() {
  /usr/bin/security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null \
    | /usr/bin/awk -v name="$IDENTITY_NAME" '$0 ~ name { print $2; exit }'
}

CREATE_MANAGED_KEYCHAIN=0
if [[ ! -e "$KEYCHAIN" ]]; then
  CREATE_MANAGED_KEYCHAIN=1
elif [[ ! -f "$KEYCHAIN" || ! -f "$PASSWORD_FILE" ]]; then
  echo "The helper-owned signing keychain is incomplete; it will not be replaced automatically: $KEYCHAIN" >&2
  exit 1
elif ! /usr/bin/security unlock-keychain -p "$(<"$PASSWORD_FILE")" "$KEYCHAIN" 2>/dev/null; then
  echo "The helper-owned signing keychain cannot be unlocked; it will not be replaced automatically: $KEYCHAIN" >&2
  exit 1
elif [[ ! "$(existing_identity)" =~ ^[0-9A-F]{40}$ ]]; then
  echo "The helper-owned signing keychain has no usable $IDENTITY_NAME identity; it will not be replaced automatically: $KEYCHAIN" >&2
  exit 1
fi

if [[ "$CREATE_MANAGED_KEYCHAIN" -eq 1 ]]; then
  PASSWORD="$(/usr/bin/openssl rand -hex 32)"
  /usr/bin/printf '%s' "$PASSWORD" > "$PASSWORD_FILE"
  /bin/chmod 600 "$PASSWORD_FILE"

  /usr/bin/security create-keychain -p "$PASSWORD" "$KEYCHAIN"
  /usr/bin/printf '%s' "$EXPECTED_MARKER" > "$OWNERSHIP_MARKER"
  /bin/chmod 600 "$OWNERSHIP_MARKER"
  /usr/bin/security set-keychain-settings -lut 21600 "$KEYCHAIN"
  /usr/bin/security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"

  IDENTITY_TEMP="$(/usr/bin/mktemp -d /private/tmp/deepseek-harness-signing.XXXXXX)"
  PRIVATE_KEY="$IDENTITY_TEMP/private-key.pem"
  PKCS12_FILE="$IDENTITY_TEMP/identity.p12"

  /usr/bin/openssl req \
    -x509 \
    -newkey rsa:3072 \
    -sha256 \
    -nodes \
    -days 3650 \
    -subj "/CN=$IDENTITY_NAME/O=Local Development/" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,digitalSignature,keyCertSign" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "$PRIVATE_KEY" \
    -out "$CERTIFICATE_FILE" >/dev/null 2>&1

  PKCS12_COMMAND=(
    /usr/bin/openssl pkcs12
    -export
    -out "$PKCS12_FILE"
    -inkey "$PRIVATE_KEY"
    -in "$CERTIFICATE_FILE"
    -passout "pass:$PASSWORD"
  )
  # `-legacy` is required by OpenSSL 3 for a PKCS#12 import that macOS Security
  # accepts, but macOS's bundled LibreSSL does not implement that option.
  if /usr/bin/openssl version 2>/dev/null | /usr/bin/grep -q '^OpenSSL 3'; then
    PKCS12_COMMAND+=( -legacy )
  fi
  "${PKCS12_COMMAND[@]}" >/dev/null 2>&1

  /usr/bin/security import "$PKCS12_FILE" \
    -k "$KEYCHAIN" \
    -P "$PASSWORD" \
    -T /usr/bin/codesign >/dev/null
  # `add-trusted-cert` writes user trust settings and can require interactive
  # authorization. A local development identity only needs its private key and
  # code-signing certificate for codesign; it does not need to become a trusted
  # root certificate.
  /usr/bin/security set-key-partition-list \
    -S apple-tool:,apple: \
    -s \
    -k "$PASSWORD" \
    "$KEYCHAIN" >/dev/null

  /bin/unlink "$PRIVATE_KEY"
  /bin/unlink "$PKCS12_FILE"
  /bin/rmdir "$IDENTITY_TEMP"
  IDENTITY_TEMP=""
fi

PASSWORD="$(<"$PASSWORD_FILE")"
/usr/bin/security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"

if ! /usr/bin/security list-keychains -d user \
    | /usr/bin/sed -E 's/^[[:space:]]*"(.*)"$/\1/' \
    | /usr/bin/grep -Fqx "$KEYCHAIN"; then
  CURRENT_KEYCHAINS=()
  while IFS= read -r existing_keychain; do
    [[ -z "$existing_keychain" ]] || CURRENT_KEYCHAINS+=("$existing_keychain")
  done < <(
    /usr/bin/security list-keychains -d user \
      | /usr/bin/sed -E 's/^[[:space:]]*"(.*)"$/\1/'
  )
  /usr/bin/security list-keychains -d user -s "${CURRENT_KEYCHAINS[@]}" "$KEYCHAIN"
fi

IDENTITY_HASH="$(
  existing_identity
)"

if [[ ! "$IDENTITY_HASH" =~ ^[0-9A-F]{40}$ ]]; then
  echo "No valid $IDENTITY_NAME identity in $KEYCHAIN" >&2
  exit 1
fi

/usr/bin/printf '%s\n%s\n' "$IDENTITY_HASH" "$KEYCHAIN"
