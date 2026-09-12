# Venue offline hub architecture

Status: foundation in progress on `feature/venue-offline-hub`.

## Known issues before release

- The staff PIN-entry layout can overflow by approximately 35 pixels on a
  medium-size tablet (`staff_pin_gate.dart`). Make the content vertically
  adaptive/scrollable and verify keyboard-open, landscape and large-text
  layouts before the offline hub is released.

## Safety invariants

1. A device never reports an offline operation as saved until the primary hub
   has committed it using SQLite `WAL` journaling and `synchronous=FULL`.
2. Every client keeps its own durable outbox until that acknowledgement.
3. Only one manager-enrolled primary hub generation may accept writes.
4. Local-network location grants no trust. Users and devices authenticate on
   every request and every object is checked against its tenant and venue.
5. Financial state is derived from immutable events. Existing payments and
   closed bills are corrected with new events, never overwritten.
6. Cloud ingestion uses the local event ID as an idempotency key and validates
   the entire event rather than trusting client-calculated totals.
7. PINs, Firebase tokens, card details and cryptographic keys are never placed
   in event payloads or diagnostic logs.
8. Every event records the authoritative UTC time, the device-observed UTC
   time, clock source and measured skew. A skew above two minutes is surfaced
   to staff and retained for reconciliation rather than silently trusted.
9. When a hub generation owns venue writes, any client that cannot reach that
   hub is fail-closed. Cloud connectivity alone must not create a competing
   order history.

## Durable event lifecycle

`pending -> inFlight -> synced`

An invalid or conflicting event moves to `quarantined` and remains available
for manager reconciliation. A process interruption resets `inFlight` events to
`pending`; replay is safe because event IDs are idempotent.

Each encrypted event records a device/staff identity, operation type, business
timestamp, hub epoch, sequence number, previous hash and authenticated event
hash. Tenant, venue and payload data live inside the encrypted envelope. The
unencrypted venue lookup key is an HMAC pseudonym rather than its Firebase ID.

Order state is rebuilt by a deterministic projector. It rejects cross-venue
events, stale hub generations, missing/duplicate sequences, edits after close,
duplicate payments, overpayment and closing with an outstanding balance. Cloud
ingestion will run equivalent validation before acknowledging an event.

## Trusted time

- During normal online operation, a Firebase function supplies Google server
  time and the venue timezone. The client estimates offset at the midpoint of
  the request round trip; it never changes the device operating-system clock.
- During an outage, the enrolled primary venue hub supplies the authoritative
  time and its current hub generation.
- Orders and payments retain server/hub time, device-observed time, measured
  skew and venue-local display snapshots. Historic receipts therefore do not
  change when a device timezone or clock is corrected later.
- An unsynchronised device may not become an offline authority without a
  manager-visible warning and a recorded recovery decision.

## Web clients and split-brain prevention

Firebase Hosting remains the normal online host. For offline browser use, the
venue hub will serve/cache the signed web application over authenticated local
HTTPS and expose an authenticated WebSocket/API on the venue LAN. Local-network
location is never treated as authentication; device enrolment, staff PIN
session, tenant and venue are checked on every mutation.

When the hub owns write authority:

- a web browser on the venue LAN writes through the hub;
- Android, iOS and Windows clients on the LAN write through the same hub;
- a browser on 3G or another network can continue to read cloud state but is
  read-only until it can reach the hub or the hub has reconciled and released
  authority;
- if neither Firebase nor the hub is reachable, web mutation controls are
  unavailable rather than creating a second order history.

Browser delivery must include a trusted venue certificate, strict origin
allow-listing, Private Network Access/CORS handling and encrypted device
credentials. There will be no unauthenticated HTTP endpoint on the LAN.

## Initial offline scope

- Open tables and named tabs.
- Draft, send, split and close orders.
- Kitchen, bar and receipt printing over the venue LAN.
- Cash payments and externally approved card-terminal payments.
- Stock reservations and deductions derived from order events.
- Locally cached staff PIN authentication and permission snapshots.

Platform administration, role changes, staff creation, online payments,
cross-venue voucher redemption and subscription changes remain online-only.

## Delivery phases

1. Encrypted local event ledger and client outbox. **Implemented foundation.**
2. Deterministic order/payment projection from those events. **Implemented
   foundation; full POS command wiring remains.**
3. Trusted Firebase/hub clock and fail-closed client routing policy.
   **Implemented foundation.**
4. Manager-approved device enrolment and per-device credentials.
5. Authenticated local HTTPS API and real-time event stream.
6. Primary hub lease/generation and explicit recovery takeover.
7. Wire POS order/payment commands through the route and durable projector.
8. LAN print routing with unknown-after-power-loss recovery.
9. Server-validated Firebase ingestion and reconciliation UI.
10. Android foreground hub service and reboot recovery.
11. Optional enrolled backup hub after split-brain testing.

The local HTTPS/WebSocket transport and end-to-end offline POS command routing
are not yet complete. The current code establishes the durable, temporal and
deterministic safety primitives they will use; it must not yet be presented to
a pilot venue as fully offline capable.

## Required failure tests

- Remove internet during every order and payment transition.
- Remove hub power before and after its durable acknowledgement.
- Remove printer power before, during and after physical printing.
- Restart while uploads are in flight.
- Attempt replay, reordering, payload modification and cross-venue access.
- Run an old hub after a manager takeover creates a newer generation.
- Fill the disk and exhaust queue limits.
- Roll the device clock backward and forward.
- Revoke a device/staff account while a venue is offline, then reconnect.
- Restore an encrypted backup onto approved replacement hardware.
