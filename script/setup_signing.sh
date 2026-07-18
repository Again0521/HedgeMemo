#!/usr/bin/env bash
set -euo pipefail

# Creates a stable, self-signed code-signing identity in the login keychain so
# every rebuild of HedgeMemo carries the SAME code signature. macOS TCC (Screen
# Recording, Accessibility) keys its grants on the signing identity; with the
# default ad-hoc signature the cdhash changes on every build, so the system
# treats each update as a brand-new app and forgets the permission. Run this
# once; afterwards `build_and_run.sh` signs with this identity automatically and
# the screen-recording grant survives updates.

IDENTITY_NAME="HedgeMemo Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# A self-signed cert is not trusted for the codesigning policy, so it never
# appears in `find-identity -p codesigning`; detect it by name instead.
if security find-certificate -c "$IDENTITY_NAME" >/dev/null 2>&1; then
  echo "Signing identity already present: $IDENTITY_NAME"
  exit 0
fi

echo "Creating self-signed code-signing identity: $IDENTITY_NAME"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/openssl.cnf" <<'CNF'
[req]
distinguished_name = req_dn
x509_extensions = v3_codesign
prompt = no
[req_dn]
CN = HedgeMemo Local Signing
[v3_codesign]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/openssl.cnf" >/dev/null 2>&1

# Import the key and certificate separately rather than via PKCS12: macOS ships
# LibreSSL (no `-legacy`), and its p12 MAC is rejected by `security import`.
# `security` pairs the matching key + cert into a usable signing identity.
# -A lets codesign use the private key without a per-build access prompt.
security import "$TMP/key.pem" -k "$KEYCHAIN" -A -T /usr/bin/codesign
security import "$TMP/cert.pem" -k "$KEYCHAIN" -A -T /usr/bin/codesign

echo
echo "Done. Rebuild with ./script/build_and_run.sh — it will sign with this identity."
echo "The next launch will ask once for Screen Recording; after that, updates keep it."
