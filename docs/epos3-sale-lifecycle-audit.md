# EPOS 3 sale lifecycle audit

This document records the authoritative path for a live sale. It exists to
stop a future change from accidentally reintroducing a direct Firestore write
or a second printing path.

## Authority from selection to settlement

1. A waiter selects a table, named tab, collection, or delivery identity.
2. `ActiveOrderController` creates a unique local order/line identity and asks
   `ProductionCommandRepository` to persist the draft.
3. When venue-hub routing is enabled, every operational mutation is a signed,
   PIN-authorised hub event. A remote terminal waits for the active hub's
   durable acknowledgement; it never treats insertion into the cloud relay as
   a successful order.
4. The hub revalidates the product, variant, modifiers, stock, permissions,
   venue, hub generation, retry identity, and printer route before appending
   the event to its encrypted ledger.
5. POS screens consume the resulting live projection. Firestore is the cloud
   replica for cross-network devices and reporting, not a second order writer.
6. Send creates one immutable production event. The hub derives kitchen/bar
   payloads and places them in its encrypted device queue.
7. Checkout records all tenders plus the close decision in one idempotent
   `payment.batchRecorded` event. This prevents a connection loss between
   separate payment and close calls from creating an accepted payment that the
   till reports as unsuccessful.
8. A paid or part-payment receipt is derived from the accepted projection. It
   contains the venue currency total, tender currency/rate/change, payment
   time, item dates, options, notes, tax snapshot, and remaining balance.
9. The signed event chain is uploaded to Firebase. Cloud ingestion verifies
   the hub signature, epoch, hash sequence, staff identity, order identity,
   prices and balances before updating the cloud projection and immutable bill.

## Printing invariants

- Production and receipt payloads are created only from authoritative order
  snapshots; terminals cannot supply arbitrary prices or item text.
- A queue claim is atomic and belongs to one enrolled device.
- After physical output succeeds, an interrupted completion acknowledgement
  is retried without printing another copy during the same app process.
- Once a sale event is durable, a transient print-queue or live-view failure
  cannot turn it into a rejected terminal command. The hub retains and retries
  those idempotent post-commit effects while it remains running.
- Removing an already-sent item creates a clearly marked cancellation ticket.
- Android/Windows workers remain independent of the active staff PIN after the
  device and venue have been enrolled.
- The legacy Firestore print queue currently remains only for server-created
  vouchers, refunds, historical reprints, and migration jobs. It cannot be
  removed until those operations are represented in the hub ledger.

## Remaining migration blocker

Bill splitting is intentionally fail-closed while hub routing is active. A
safe implementation needs one atomic ledger transaction that mutates the
source order and creates the child order together. Calling the old cloud-only
`splitOrder` handler would bypass the hub and is therefore not an acceptable
shortcut. This is the next EPOS 3 protocol migration, not dead code to delete.
The UI reports this as unavailable without suggesting that staff disable the
venue's security boundary.

## Required regression run

- Start/open every location type on the hub and on a remote terminal.
- Add, reduce, remove, discount, send, and reopen from a second device.
- Exercise no-print, production print, cancellation, pre-receipt, part-payment
  receipt, split tender, paid receipt, retry, fallback, and reprint paths.
- Repeat with internet available, internet unavailable on the venue LAN, and a
  remote terminal on a different connection while the hub remains online.
- Confirm tables/tabs release only after a zero-balance close and that bills,
  stock movements, production tickets, audit events, and reports converge.
