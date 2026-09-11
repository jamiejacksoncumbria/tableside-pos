# Venue offline hub architecture

Status: foundation in progress on `feature/venue-offline-hub`.

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

## Durable event lifecycle

`pending -> inFlight -> synced`

An invalid or conflicting event moves to `quarantined` and remains available
for manager reconciliation. A process interruption resets `inFlight` events to
`pending`; replay is safe because event IDs are idempotent.

Each encrypted event records a device/staff identity, operation type, business
timestamp, hub epoch, sequence number, previous hash and authenticated event
hash. Tenant, venue and payload data live inside the encrypted envelope. The
unencrypted venue lookup key is an HMAC pseudonym rather than its Firebase ID.

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

1. Encrypted local event ledger and client outbox.
2. Deterministic order/payment projection from those events.
3. Manager-approved device enrolment and per-device credentials.
4. Authenticated local HTTPS API and real-time event stream.
5. Primary hub lease/generation and explicit recovery takeover.
6. LAN print routing with unknown-after-power-loss recovery.
7. Server-validated Firebase ingestion and reconciliation UI.
8. Android foreground hub service and reboot recovery.
9. Optional enrolled backup hub after split-brain testing.

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
