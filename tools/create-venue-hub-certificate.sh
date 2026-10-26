#!/usr/bin/env bash
set -euo pipefail

# Creates a venue-specific private CA/server certificate for a TableSideCY hub.
# Works on macOS, Linux and Android Termux with OpenSSL 1.1.1 or newer.

hub_host="${1:-}"
output_directory="${2:-./local-secrets/venue-hub-tls}"
valid_years="${3:-10}"

if [[ -z "$hub_host" || ! "$hub_host" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "Usage: $0 HUB_HOST [OUTPUT_DIRECTORY] [VALID_YEARS]" >&2
  echo "Example: $0 192.168.1.20 ./local-secrets/venue-hub-tls 10" >&2
  exit 2
fi

if [[ ! "$valid_years" =~ ^[0-9]+$ ]] || (( valid_years < 1 || valid_years > 30 )); then
  echo "VALID_YEARS must be a whole number from 1 to 30." >&2
  exit 2
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "OpenSSL is required. In Termux run: pkg install openssl" >&2
  exit 1
fi

umask 077
mkdir -p "$output_directory"

certificate="$output_directory/venue-hub-certificate.pem"
private_key="$output_directory/venue-hub-private-key.pem"
trust_certificate="$output_directory/venue-hub-trust-certificate.cer"
days=$((valid_years * 365))

if [[ "$hub_host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  subject_alt_name="IP:$hub_host"
else
  subject_alt_name="DNS:$hub_host"
fi

openssl req \
  -x509 \
  -newkey rsa:3072 \
  -sha256 \
  -nodes \
  -days "$days" \
  -subj "/CN=$hub_host" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth" \
  -addext "subjectAltName=$subject_alt_name" \
  -keyout "$private_key" \
  -out "$certificate"

openssl x509 -in "$certificate" -outform der -out "$trust_certificate"
chmod 600 "$private_key" "$certificate" "$trust_certificate"

echo "Created a TableSideCY venue certificate for $hub_host ($valid_years years)."
echo "Certificate PEM: $certificate"
echo "Private key PEM: $private_key"
echo "Trust certificate: $trust_certificate"
echo "Import the certificate and private key only on the hub."
echo "Import only the certificate PEM on ordinary POS devices."
echo "Delete exported private-key copies after the hub import succeeds."
