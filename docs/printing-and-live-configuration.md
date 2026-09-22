# Printing and live configuration

This note documents the operational invariants that must be preserved when
changing printing, staging environments, the offline hub, menus or fulfilment.

## Source of truth

- Firestore is the cloud source for menu, venue, customer and fulfilment
  configuration.
- When a venue hub is enabled, its encrypted snapshot is the native POS source
  while online or offline. Successful configuration writes explicitly ask the
  hub to refresh; a 30-second authority poll remains the recovery path.
- Firestore staging and production use the same code paths. Environment
  selection changes only Firebase options and never bypasses the hub, PIN,
  audit or printer rules.

## Operational printing

- Without hub authority, Cloud Functions creates and owns Firestore print jobs.
- With hub authority, the hub creates jobs in its encrypted durable queue before
  acknowledging the order event. This queue survives an app or power restart.
- A requested print with no active venue route is rejected visibly. It is never
  silently discarded.
- The physical printer worker marks a job printed only after the native printer
  API accepts the bytes. Failures retry three times, then remain visible for
  manager recovery; printed history is retained for five days.
- The recovery and alert screens merge legacy Firestore jobs with hub-local
  jobs. Manager retry, reprint and cancellation of a hub job are authenticated
  by the device signature and manager PIN session, and are added to the audit
  ledger.

## Several printers on one Windows device

The venue route chooses the physical TableSideCY device. The Windows printer
setup then chooses the installed queue on that device. Receipt, kitchen, bar
and dessert may each bind to a different Windows queue. If no area-specific
binding exists, the existing device-default selection is used, preserving old
installations.

Test prints validate only the selected Windows/Bluetooth transport. A complete
acceptance test must also create an operational order, confirm the job appears
in **Print queue & recovery**, and verify the routed hardware prints it.
