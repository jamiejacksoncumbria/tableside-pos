# Venue offline hub

Status: pilot implementation on `feature/venue-offline-hub`.

The venue hub lets native Android and Windows tills continue essential service
when the venue Wi-Fi is working but its internet connection is unavailable. One
manager-enrolled native device is the venue authority. Other enrolled native
devices connect to it over authenticated local HTTPS.

Web builds remain cloud-connected and read-only when a venue hub owns write
authority. Browsers do not currently write through the LAN hub. This avoids
browser certificate, private-network and split-brain behaviour that cannot be
made reliable across every browser in the pilot.

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

## Setup

1. Give the proposed hub and every native till/printer a stable LAN address.
2. Generate a venue TLS certificate with
   `tools/create-venue-hub-certificate.ps1`. Install its CA certificate as
   trusted on every participating device.
3. In **Settings > Venue offline hub**, enter the hub LAN address, import the
   certificate and private key on the hub device, then choose **Make this the
   hub**.
4. On every other native device, open the same page and choose **Enrol this
   till / printer** while internet is available.
5. Configure venue printer devices and primary/fallback routes normally.
6. Keep the hub app open. Automatic Android boot/foreground-service startup is
   not part of this pilot, so a device restart requires reopening TableSide.

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
- Verify web can read cloud data but cannot mutate while hub authority is
  active.
- Check the known medium-tablet PIN screen overflow separately; it is a UI
  issue already recorded for the next responsive-layout pass.
