# TableSide security change checklist

Before merging a feature that touches users, venues, orders, payments,
printing, inventory, reports, or Firebase:

1. Define the selected PIN role that may perform the action.
2. Enforce it in the trusted `posApi`/`platformApi` handler; never rely on a
   hidden Flutter button.
3. Check the underlying Firebase host account remains active and scoped to the
   same restaurant.
4. Review Firestore and Storage rules for read as well as write access.
5. Require audit events and a human-readable reason for sensitive mutations.
6. Confirm a changed/locked/retired PIN invalidates existing sessions.
7. Log errors without logging PINs, session tokens, credentials, card details,
   or customer data.
8. Test ordinary staff, manager, owner, printer-device, retired-user, and
   cross-venue behaviour.
