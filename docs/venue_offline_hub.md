# Venue offline hub

Status: pilot implementation on `feature/venue-offline-hub`.

The venue hub lets native Android and Windows tills continue essential service
when the venue Wi-Fi is working but its internet connection is unavailable. One
manager-enrolled native device is the venue authority. Enrolled Android,
Windows and iOS POS devices connect to it over authenticated local HTTPS. iOS
is client-only for this release; web remains online-only.

Web and native devices away from the venue LAN submit short-lived commands to
a venue-specific Firebase queue. The active hub must maintain a fresh signed
heartbeat, claim the command, revalidate it, commit it durably and acknowledge
it before the remote POS reports success. If the heartbeat is stale, remote
ordering stops. The LAN path remains available during a venue internet outage.

## Pilot scope

Available through the hub:

- select a table or named tab and view live orders;
- create orders, add/update draft lines and send new lines;
- record partial cash or externally approved card payments;
- close fully paid orders and request pre-receipts;
- route kitchen, bar, dessert and receipt tickets to enrolled Android or
  Windows printer devices;
- retry the primary printer three times, then its configured fallback three
  times;
- reserve tracked stock and recipe components when lines are sent;
- authenticate cached venue staff with six-digit PINs;
- sync immutable events, stock movements, payments and audit records back to
  Firebase after connectivity returns.

Online-only in this pilot: split bills, line discounts/corrections, refunds,
gift vouchers, bookings, menu/stock administration, platform administration,
online payments and subscription changes. These actions fail closed while the
hub is required and unreachable; they never create a competing cloud history.

## Safety rules

1. A command is reported as saved only after the hub commits it to encrypted
   SQLite with WAL journaling and `synchronous=FULL`.
2. The hub assigns immutable IDs, trusted UTC timestamps, a strictly increasing
   sequence, previous-event hash and authenticated event hash.
3. Semantic command IDs make client retries safe after a lost acknowledgement.
4. Only the current cloud-authorised hub generation accepts writes. A newer
   generation stops the old hub as soon as it next reaches Firebase.
5. Every LAN request is signed by an enrolled Ed25519 device credential and
   checked for timestamp, nonce replay, tenant, venue and staff PIN session.
6. Local-network access is never treated as authentication.
7. Prices, tax, modifiers, variants, availability, stock and printer routes are
   canonicalised from the signed venue snapshot; client values are not trusted.
8. Financial history is append-only. Payments retain tender/base currencies,
   exchange rate, change, UTC timestamp and venue business date.
9. PIN failures are stored as immutable security events with staff, device,
   venue, time, success and lock status.
10. Secrets, PINs, Firebase tokens and card details are never written to the
    event log or diagnostic output.
11. Remote commands expire after 25 seconds, use transactional claim leases
    and carry an idempotency key into the immutable ledger. Firebase clients
    cannot write command state directly.
12. A remote client never falls back to ordinary cloud order mutations while
    hub authority is active. Its visible waiting banner remains until the hub
    confirms the durable commit.

## Setup

1. Reserve one fixed IP address for the proposed Android or Windows hub in the
   venue router. Ordinary tills/printers do not need fixed addresses.
2. Generate one certificate pair for the venue with
   `tools/create-venue-hub-certificate.ps1`. The certificate must contain the
   reserved hub IP. Keep `venue-hub-private-key.pem` as a venue secret; it is
   needed only by the active or replacement hub.
3. On the proposed hub, open **Settings > Venue offline hub**, enter its
   reserved LAN IP, import both `venue-hub-certificate.pem` and
   `venue-hub-private-key.pem`, then choose **Make this the hub**. TableSideCY
   pins the exact public certificate, so Android/iOS system CA installation is
   not required for the app itself.
4. On every other Android, Windows or iOS POS/printer device, open **Venue
   offline connection**, import only the same `venue-hub-certificate.pem`, and
   choose **Enrol this till / printer** while internet is available. Never copy
   the private key to an ordinary till.
5. Configure venue printer devices and primary/fallback routes normally.
6. On an Android hub, select **Battery settings**, give TableSideCY unrestricted
   battery use, keep the terminal powered, and disable vendor-specific app
   sleeping/Wi-Fi switching. A foreground service holds the CPU and Wi-Fi
   while the hub runs.
7. After an Android reboot, the persistent notification asks an operator to
   reopen TableSideCY once. This is deliberate: Android can restart the native
   service, but it cannot unlock and reconstruct the encrypted Dart hub safely
   until the application is opened. The notification changes to **venue hub is
   active** only after the HTTPS server is genuinely ready.

A manager takeover is intentionally explicit and audited. Confirm the previous
hub is stopped before replacing it. Cloud activation is refused while Firebase
knows of open venue orders; an old isolated hub may still contain unsynchronised
orders, so takeover always requires an operational reconciliation check.

## Data and power failure

Committed orders survive application, device and venue power loss in the hub's
encrypted local database. Claimed-but-unconfirmed print jobs return to the
queue after restart. Pending cloud uploads remain locally stored until
acknowledged. Regular device backups are still required because loss of the
physical hub and its protected encryption key is not recoverable from an
ordinary database-file copy alone.

## Required pilot tests

- Remove internet before, during and after draft, send, partial payment and
  final payment operations.
- Kill and restart the hub before and after its save confirmation.
- Power off printers before, during and after printing; verify three retries,
  fallback routing and recovery after restart.
- Add products until tracked stock reaches zero and verify manager override.
- Use two tills on the LAN and confirm order changes appear on both within two
  seconds without duplicate lines/payments.
- Set a client clock more than two minutes wrong and verify the retained skew
  warning while hub time remains authoritative.
- Revoke a staff member/device and change a PIN while online; verify refreshed
  snapshots invalidate existing local sessions.
- Attempt a replay, modified signature, stale hub generation and cross-venue
  request; all must fail.
- Restore power with pending events and confirm cloud orders, payments, stock
  movements and audit events reconcile once and only once.
- Put a web/4G device outside the venue LAN and verify it can order only while
  the hub heartbeat is fresh, displays **Waiting for venue hub**, and receives
  the accepted result through Firebase streams.
- Stop the hub while Firebase remains online and verify remote commands fail
  closed without creating orders, stock changes, payments or print jobs.
- Check the known medium-tablet PIN screen overflow separately; it is a UI
  issue already recorded for the next responsive-layout pass.

## iOS POS test setup

iOS 13 or later is supported as a POS client, not as a hub. Firebase options,
the CocoaPods file, camera permission and local-network permission are present
in the project. A Mac with current Xcode and an Apple development team is still
required to build and sign the app:

```bash
flutter pub get
cd ios
pod install
cd ..
flutter run -d <iphone-device-id> --dart-define=TABLESIDE_USE_FIREBASE=true
```

Open `ios/Runner.xcworkspace` in Xcode once, select the Runner target, choose
the Apple team, and confirm the bundle identifier is
`uk.co.gopcpitstop.tablesideCY`. The first hub connection triggers Apple's local
network permission prompt; allow it. Debug builds use Firebase App Check's
debug provider, so register the printed iOS debug token in Firebase before
enforcing App Check. Push notifications additionally require the Push
Notifications capability and an APNs key in Firebase, and should be validated
on a physical iPhone rather than only the simulator.

## Post-pilot certificate hardening

The pilot already pins the exact hub certificate and authenticates every
request with an enrolled device key. A later security pass should replace the
manually distributed self-signed leaf with a per-venue private CA and separate
short-lived hub certificate, add overlap-based rotation and explicit
revocation, warn before certificate expiry, and use hardware-backed private
keys/device attestation where the terminal supports them. Mutual TLS can then
be assessed in addition to the existing signed-request protocol.
