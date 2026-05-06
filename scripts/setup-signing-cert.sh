#!/bin/bash
set -euo pipefail

# ─── One-off Code Signing Cert Setup ──────────────────────────────────
# Creates a self-signed Code Signing certificate in the user's login
# keychain so build-app.sh can produce binaries with a STABLE signing
# identity. Why this matters: macOS TCC (privacy permissions like Screen
# Recording) keys ad-hoc-signed apps by cdhash, which changes on every
# rebuild — forcing the user to re-grant permission after each compile.
# A stable cert keys TCC by signing-identity hash instead, so rebuilds
# inherit the previous grant.
#
# Run once; idempotent. Safe to re-run.
#
# Usage:
#   ./scripts/setup-signing-cert.sh
#
# After this completes, scripts/build-app.sh will detect the cert and
# sign with it automatically.

CERT_NAME="Scribe Local Signer"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -F -q "\"$CERT_NAME\""; then
    echo "✓ Code signing identity already in keychain: $CERT_NAME"
    echo "  (re-run with --force to recreate)"
    if [ "${1:-}" != "--force" ]; then
        exit 0
    fi
    echo "  --force given: deleting existing identity..."
    security delete-identity -c "$CERT_NAME" "$LOGIN_KEYCHAIN" 2>/dev/null || true
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# OpenSSL config: minimal Code Signing leaf cert. extendedKeyUsage =
# codeSigning is the field the macOS Security framework looks for when
# `security find-identity -p codesigning` filters identities.
cat > "$TMPDIR/openssl.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
prompt = no
[req_distinguished_name]
CN = $CERT_NAME
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

echo "[1/3] Generating private key + self-signed cert..."
openssl genrsa -out "$TMPDIR/key.pem" 2048 2>/dev/null
openssl req -new -x509 -days 3650 -sha256 \
    -key "$TMPDIR/key.pem" \
    -out "$TMPDIR/cert.pem" \
    -config "$TMPDIR/openssl.cnf" \
    -extensions v3 2>/dev/null

# Drop a previously-imported cert with the same name so duplicates don't
# accumulate on re-runs.
security delete-certificate -c "$CERT_NAME" "$LOGIN_KEYCHAIN" 2>/dev/null || true

echo "[2/3] Importing cert + private key (PKCS12, macOS-compatible PBE)..."
# PKCS12 with the legacy PBE-SHA1-3DES crypto + SHA1 MAC. macOS
# `security import` reliably handles this combo; openssl 3.x defaults
# (AES-256-CBC + SHA-256 MAC) tripped MAC verification on macOS 14/15,
# and the split cert-then-key route loaded both items but never linked
# them as an identity (find-identity returned 0). Pin algorithms
# explicitly so the script doesn't drift when openssl defaults change.
P12_PASS="scribe-local-dev"
openssl pkcs12 -export -legacy \
    -keypbe PBE-SHA1-3DES \
    -certpbe PBE-SHA1-3DES \
    -macalg sha1 \
    -out "$TMPDIR/identity.p12" \
    -inkey "$TMPDIR/key.pem" \
    -in "$TMPDIR/cert.pem" \
    -name "$CERT_NAME" \
    -passout "pass:$P12_PASS" 2>/dev/null

# -T whitelists codesign / security to use the private key without
# popping a Keychain access dialog every signing run.
security import "$TMPDIR/identity.p12" \
    -k "$LOGIN_KEYCHAIN" \
    -P "$P12_PASS" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    >/dev/null

echo "[3/4] Marking cert as trusted root for code signing (per-user)..."
# Without this, `find-identity -v -p codesigning` filters our self-signed
# cert out as CSSMERR_TP_NOT_TRUSTED, and codesign refuses to use it.
# `-r trustRoot -p codeSign -k login.keychain-db` adds the trust setting
# to the per-user store (no sudo needed). May pop a one-time auth prompt.
if security add-trusted-cert -r trustRoot -p codeSign \
    -k "$LOGIN_KEYCHAIN" \
    "$TMPDIR/cert.pem" >/dev/null 2>&1; then
    echo "  ✓ Cert trusted for code signing"
else
    echo "  ⚠ Could not add trust (cancelled / authority issue)."
    echo "    Re-run the script and approve the auth prompt, or trust"
    echo "    manually in Keychain Access → Scribe Local Signer →"
    echo "    Get Info → Trust → Code Signing: Always Trust."
fi

echo "[4/4] Granting codesign access to the new key (may prompt for keychain password once)..."
# Fail-soft: this step requires the login keychain password. If the user
# cancels the prompt, the cert still works — they'll just see one
# Keychain "allow access" dialog the first time codesign runs, and can
# click "Always Allow" there. Don't abort the script.
if security set-key-partition-list \
    -S "apple-tool:,apple:,codesign:" \
    -s -k "$(security default-keychain | tr -d '" ')" \
    "$LOGIN_KEYCHAIN" >/dev/null 2>&1; then
    echo "  ✓ Partition list updated — codesign will not prompt again"
else
    echo "  ⚠ Could not update partition list (cancelled / wrong password)."
    echo "    First codesign run will show a Keychain dialog — click \"Always Allow\"."
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  ✓ Done — code signing identity ready: $CERT_NAME"
echo ""
echo "  Verify:  security find-identity -v -p codesigning"
echo "  Use:     ./scripts/build-app.sh   (auto-detects this identity)"
echo ""
echo "  Note: the FIRST .app built with this cert still needs a one-time"
echo "  TCC grant in System Settings → Privacy & Security. Subsequent"
echo "  rebuilds keep that grant intact."
echo "═══════════════════════════════════════════════════════════════"
