# Venue hub certificates

Every venue hub uses its own private TLS certificate. X.509 certificates must
have an expiry date; TableSideCY therefore defaults to ten years and permits a
controlled lifetime from one to thirty years. Ten years is recommended so a
lost or forgotten private key does not remain trusted indefinitely.

The certificate must include the hub's fixed IP address or DNS name. If that
address changes, generate and enrol a replacement certificate.

## Windows

From the repository root:

```powershell
.\tools\create-venue-hub-certificate.ps1 `
  -HubHost 192.168.1.20 `
  -ValidYears 10
```

Files are written to the ignored `local-secrets\venue-hub-tls` directory.
Use `-OutputDirectory` to select another folder and `-SkipWindowsTrust` when
the machine running the script is not the hub.

## Android hub using Termux

Install Termux from F-Droid, then run:

```bash
pkg update
pkg install git openssl
termux-setup-storage
git clone https://github.com/jamiejacksoncumbria/tableside-pos.git
cd tableside-pos
git switch test/system-testing-and-bug-fixes
bash tools/create-venue-hub-certificate.sh \
  192.168.1.20 \
  "$HOME/storage/downloads/TableSideCY-Hub" \
  10
```

In TableSideCY on the Android hub, open **Settings → Venue offline hub** and
import both `venue-hub-certificate.pem` and `venue-hub-private-key.pem`. Once
the hub starts successfully, delete the private-key file from Downloads:

```bash
rm "$HOME/storage/downloads/TableSideCY-Hub/venue-hub-private-key.pem"
```

Ordinary Android POS devices receive only `venue-hub-certificate.pem` and use
**Enrol this till / printer**. They must never receive the private key.

## Rotation

Create a new certificate before the current one expires. During a maintenance
window, import both new files on the hub, restart/replace the hub authority,
then import the new public certificate on every native POS terminal. Keep the
old files only until all terminals have moved successfully, then destroy the
old exported private key.
