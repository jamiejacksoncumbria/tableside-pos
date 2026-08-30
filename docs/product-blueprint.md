# TableSide POS product blueprint

Status: approved product/build blueprint for the Spice Garden core pilot. This
is the living source of truth for product decisions, data rules, and the
implementation order. Deferred features are deliberately designed for but not
built until their release phase; they do not delay the core pilot.

## Product principles

- TableSide is a multi-restaurant SaaS product for the UK, Turkey, Northern
  Cyprus, and Cyprus first. It must not hard-code one country's tax, currency,
  receipt, or business-day assumptions.
- Closed bills, payments, tax, exchange rates, menu prices, and audit events
  are immutable financial history. Corrections use a void, refund, adjustment,
  or replacement document; they never edit history in place.
- Every operational write records an actor, timestamp, source device, and
  reason where the action is sensitive.
- Cancellations, voids, refunds, price overrides, and manual stock adjustments
  are always sensitive actions: each requires a reason and creates an audit
  event.
- Every feature uses a central error/diagnostic boundary. Debug builds log each
  failed operation with safe context and stack trace to the development console;
  production monitoring records actionable diagnostics without passwords, PINs,
  access tokens, payment secrets, or unnecessary customer data. Firestore/queue
  failures, permission denials, offline transitions, and native print errors
  must be visible through this mechanism.
- Company defaults reduce setup effort. Venues may override them; a blank venue
  field explicitly inherits the company value.
- The Flutter app is responsive by design: Android handheld ordering, Windows
  till/print station, iOS/tablet, and web back office all use the same rules
  with device-appropriate screens.
- All permitted operational/admin features remain available on every supported
  platform; adaptive layouts optimise them for the available screen rather than
  restricting screens purely by device type. The first pilot QA priority is
  Android 14 POS terminal and Android waiter phone, then web/Windows back
  office, followed by iOS parity.
- The app supports dynamic light/dark themes, large text, high contrast, and
  colour-blind-safe status indicators from the start. Windows keyboard
  shortcuts and barcode-scanner-specific workflows are not first-release
  requirements.
- The visual direction is a modern, graphical restaurant POS: simple under
  service pressure, but visually polished rather than a dense legacy till UI.

## Organisation and tenancy

### Agreed

- A restaurant company is one legal company and may contain many venues.
- A person can belong to many companies and venues, with different roles in
  each. After email/password sign-in, they choose the company and venue they
  are working in.
- A company may have multiple owners. The final remaining owner cannot be
  retired; any ownership transfer requires an owner PIN and an audit event.
- Company details are inherited by a venue unless the venue supplies an
  override. Address, tax registration, logo, menu, and pricing need independent
  inherit/override controls.
- Each venue selects its IANA time zone from a searchable controlled list, not
  free text. Its booking times, availability schedules, business-day cut-off,
  order timers, and local reports use that venue time zone.
- The company menu is the default source for its venues. A venue uses
  field-level inheritance: it receives later company changes unless it has
  explicitly overridden that specific field (for example price or
  availability). A manager may deliberately `detach` a venue menu into a full
  independent copy; that action and its later re-attachment/reconciliation
  rules are audited.
- Reattaching a detached venue menu is allowed only through a manual migration/
  reconciliation wizard. It is never automatic, so local venue changes cannot
  silently disappear.
- Company/venue setup templates can clone menu, tax, role, and printer
  configuration into a new venue. Templates never copy sales, payments,
  bookings, staff PINs, device credentials, or other historic/secret data.
- Availability scheduling is a restaurant-controlled option. A venue may turn
  schedules on or off and, when enabled, may apply them to whole menu sections
  and/or individual products.
- Availability schedules are distinct for dine-in, takeaway, and delivery.
  `Collection` is an alternative UI label for takeaway, not a separate service
  type. Each sale type supports recurring day-of-week service windows plus
  dated overrides configured in advance, including a planned multi-day closure
  such as a week away. A section schedule supplies a default which a product
  may inherit or override; manual unavailable/sold-out state remains separate
  from scheduled availability.
- Each venue also configures opening hours for those sale types using the same
  recurring-weekly and date-override model. Public QR ordering refuses orders
  outside its applicable venue hours; a manager may make an audited staff-order
  override.
- Price schedules are separate from availability schedules. A venue may set
  future-effective prices by service type (for example lunch, happy-hour, or
  delivery pricing); every order snapshots the price schedule/version used.
- The platform administrator can enter audited, bannered support mode for a
  company.
- Platform support mode starts read-only. A platform administrator may enable
  time-limited write support only with an explicit reason; the mode, scope,
  reason, and every action are audited and shown in a clear support banner.
- SaaS subscriptions/packages, temporary paid-access overrides, and eventual
  Stripe billing are in scope. Enforcement must never delete customer data.

### Proposed data hierarchy

```text
platform
  companies (legal restaurant companies)
    venues
    memberships (user + role assignments)
    taxProfiles / taxCategories / taxRateVersions
    menuSections / products / modifierGroups
    orders / bills / payments / auditEvents
    devices / printers / printJobs
```

## Currency, tax, and payments

### Agreed

- Tax/VAT is country and product dependent. Each product must use a tax
  category/rate, rather than a single company-wide rate.
- Menu and receipt prices are always tax-inclusive, for every company and
  venue. Tax is calculated from the inclusive line price and its snapshot tax
  category/rate.
- A product may have different tax-category assignments by sale type, including
  eat-in, takeaway, and delivery. Tax category/rate selection is configured in
  the product back office, supports multiple tax categories, and is snapshotted
  on every order line/bill so later configuration changes cannot alter history.
- A company has a base **reporting currency**. A venue has its own **trading
  (functional) currency**, which may differ from the company base currency.
- The company reporting/default currency is immutable after company creation;
  it is never edited in place because that would corrupt cross-period reporting.
- A bill is priced and taxed in its venue's trading currency. The bill snapshots
  the currency, tax rate/version, prices, rounding method, and company/venue
  receipt details when it closes.
- A payment may be split across cash, card, and other methods. Each tender is a
  separate immutable record.
- If a tender currency differs from the bill currency, store the tender amount,
  bill-currency amount, reporting-currency amount, locked rate, rate source,
  timestamp, rounding result, and the staff member who approved any manual
  rate.

### Safety rules

- A venue's trading currency must be selected before its first menu price or
  transaction. Changing it later requires a controlled migration/new venue,
  never an in-place conversion of stored amounts.
- Exchange rates are quotes, not historic truth. A future FX integration must
  use a licensed provider/API rather than scrape Google, retain the provider
  quote, and permit a manager override only with a reason and audit event.
- In the pilot, foreign-cash exchange rates are manager-entered with the
  required audit reason; automated FX-provider quotes are a later integration.
- Card/online tenders should normally be requested in the bill currency; any
  provider settlement or customer dynamic-currency conversion is retained as
  provider metadata, not used to alter the bill.
- Tax configuration needs effective dates. A rate change creates a new version;
  it never rewrites closed transactions.
- Service charge, discounts, promotions, vouchers, and pooled tips are out of
  scope for the first release. The data model must reserve audited adjustment
  types so they can be added without changing closed-bill history.
- Vouchers are designed now but released after the Spice Garden pilot. The
  future tender model supports both stored-value/gift vouchers and fixed-value
  paper vouchers, with unique code, original value/currency, remaining balance,
  optional expiry, company-wide venue redemption, and full issue/redemption
  audit history.
- Only an owner or manager may void/refund a completed payment.
- Cash-up does not need floats or discrepancy sign-off initially; reports must
  show totals by tender currency and card totals.
- A venue has a daily-close snapshot: a manager records an operational summary
  of that business day's sales/tenders, selected-card-terminal totals, printer
  issues, and notes. This is not a cash-count, opening-float, or discrepancy
  sign-off workflow, and it never locks out later audited corrections.
- Spice Garden has one pilot venue. Its company base/reporting currency is
  Turkish lira, stored as ISO code `TRY` (not the display label `TL`).
- Initial tax categories include food, alcohol, takeaway, and zero-rated
  products. Each venue manager enters the applicable rates for its jurisdiction
  during setup; no country rate is hard-coded by the application.
- Tax-rate changes do not need a scheduling UI initially. The underlying data
  must still version changes so closed bills remain correct.
- The first release prints standard receipts from the bar printer, not formal
  tax invoices. Receipt minimum content is company name, date/time, ordered
  items, and total. Standard receipts also show bill number, currency, payment
  method, and tax breakdown by tax rate/category.
- Foreign-currency change may be given in a different currency. The payment
  record must capture tendered amount/currency, change amount/currency, and
  every locked conversion/rounding result.
- The bill's reporting-currency conversion rate locks when the bill closes.
  When the FX provider is unavailable, a manager may enter an override rate;
  it requires a reason, actor, timestamp, and audit record.
- Bill splits support equal shares, selected items/quantities, and custom
  amounts; they do not use seats. A split may use mixed cash, Card Plus
  terminal/card, and foreign-currency cash tenders. Deposits and partial
  payments are out of scope initially.
- An order/table can be divided repeatedly into linked payable bills for named
  groups (for example Sally + John, then Mike + Sofie). Staff allocate items or
  quantities to a new bill; the original remains a split container with the
  unallocated items. It is never falsely closed as a zero-value sale. Each
  resulting bill receives tender and closes independently.
- `Card Plus` is the intended pilot card-terminal provider. Its integration
  method, callback security, supported currencies, and refund capability must
  be validated against provider documentation before implementation.
- Until that integration is approved, staff select a configured **venue card
  terminal** (a restaurant may have several) and record `Card Plus paid` only
  after the external terminal has approved the transaction. The POS retains the
  selected terminal and the staff member as payment metadata. A typed terminal
  receipt/reference is not required for this first manual workflow; the
  selected terminal supports end-of-day reconciliation with its totals.
- The terminal-reconciliation view compares each configured terminal's declared
  end-of-day card total with the POS total of tenders recorded against it, and
  records any discrepancy/note without rewriting payments.
- A refund returns money through the original tender method and currency. A
  card payment is never silently refunded as cash; any future exception flow
  requires an explicit, separately audited policy.
- A card refund must be completed through Card Plus first. The POS then records
  the matching refund; that recording requires a manager PIN even when the
  active staff member is a manager.
- Closed bills/payments are never edited in place. A manager with PIN authority
  can correct any error through an explicit void, refund, adjustment, or
  replacement document that links to and preserves the original financial
  history.
- Customer receipts print only when a staff member explicitly selects `Print
  receipt`. The order screen also provides a non-payment **draft receipt/bill**
  print action for a customer to inspect at the table. Digital/email receipts
  are later work.
- A draft bill prominently says `DRAFT — NOT PAID`, shows the current items,
  tax, and total, and never enters sales reporting or payment records.
- A table-reservation deposit is not an open food/drink bill. It is a separate
  immutable booking-deposit credit/payment, issued to the named customer and
  venue with its own receipt. On the visit date, an authorised user applies it
  as a linked credit to the final bill; the original payment and its link remain
  auditable. It continues until it is applied, refunded, forfeited, or
  transferred by the documented manager process; it has no automatic expiry.
- Booking deposits are configurable per booking and may be paid by cash or
  Card Plus/card initially; online payment is designed for later. A deposit
  may be applied to any final bill for the same named customer at the same
  venue.
- Reports show booking-deposit money separately from food/drink sales and
  separately show booking-deposit credits applied to final bills.

### Compliance and later integrations

- The venue manager enters the applicable tax categories/rates; they are never
  hard-coded. Before activating a country, its fiscal-receipt, registration,
  retention, and accounting-export requirements require a local professional
  review.
- Pilot foreign-cash uses the agreed audited manual rate. Choosing a licensed
  FX provider, quote cadence, and any future automated change workflow belongs
  to the later FX integration release.

## Identity, roles, and devices

### Agreed

- Staff authenticate using email/password. A quick local PIN selects/locks the
  currently active staff session and automatically locks after an agreed idle
  period; it does not replace the initial identity login.
- A manager can invite a new staff member with a set-password email. If that
  email already has an account, the manager assigns a new membership rather
  than creating a duplicate Firebase Auth user.
- Staff can have different roles at different companies and venues.
- Managers have full restaurant operational access. Waiters take orders and
  close bills. Sensitive actions require a manager PIN.
- Retiring a staff account disables access immediately but retains historic
  attribution.
- Every create, edit, discount, void, payment, refund, ticket, and print event
  is auditable.
- Tips are expected to be pooled; shift/clock-in reporting is a later feature.
- Standard roles are company owner, manager, combined waiter/cashier,
  kitchen/bar, reporting-only, temporary staff, and device. A manager may
  create company-specific custom roles from permissions; owner/platform
  controls remain protected.
- Only the company owner may create, promote, or demote a manager. A manager
  may assign roles only below manager level, within the company's permitted
  custom-role configuration.
- Kitchen/bar staff see production tickets and status controls only, not
  financial or customer information.
- Staff choose company and venue each time they sign in, and shared devices
  provide a clear switch-staff action. The app locks after 30 minutes and
  requires PIN to continue; staff explicitly sign out at end of shift.
- On a personal device, staff use email/password and choose company and venue on
  every sign-in. A manager assigns each shared till/printer terminal to one
  venue; its PIN-only screen lists only active staff assigned to that venue.
  Moving the device to another venue requires manager reconfiguration.
- On an enrolled shared device, staff first select their displayed name and then
  enter their six-digit PIN. The PIN-only screen deliberately does not grant
  access to a staff identity that has not been selected; this prevents a
  coincidental shared PIN from selecting the wrong staff account.
- Temporary staff may receive a time-limited company/venue membership.
- Shared-device staff switching uses PIN-only authentication after a device is
  enrolled by a manager. PINs are six digits; three failed attempts trigger a
  temporary lock. This requires server-side, salted PIN verification plus an
  audit/device binding, not PIN values stored on the device.
- Three failed PIN attempts lock the PIN account/device flow. An audited,
  single-use email unlock link and alert is sent to every current manager of
  the venue. A recipient must sign in before unlocking the staff PIN.
- A staff member may change their own PIN after email/password authentication;
  a manager or owner may force a PIN reset. Both flows are auditable.
- Temporary memberships use a custom end date.
- Custom company roles may grant all operational permissions: order, cancel,
  payment, refund, price edit, menu edit, report view/export, printer
  management, and staff management.
- Platform full administrators select SaaS plans, manage terminal hire, and
  create customer invoices. Company owners can view/download their invoices and
  payment status but cannot mark manual invoices paid.
- Both the platform administrator and company owner may request a company's
  data deletion. The initial action is an archive to read-only, rather than
  physical deletion. A platform administrator must approve it after the
  legal-retention check; the request, approval, and archive are auditable.
- A platform administrator may restore an archived company to active status;
  restoration is a separate major audit event.

### Design decision

`Printer` must be a trusted **device identity**, not a human staff role. A
native Windows/Android print-station app claims jobs for its assigned printers;
it cannot order, see sales, or manage staff. A future `kitchen` staff role can
operate the kitchen-display screen without granting financial permissions.

### Protected capabilities

- Managers can design/assign below-manager custom roles using all listed
  operational permissions. Only owners may create/promote/demote managers;
  only platform administrators control support access, SaaS plans, terminal
  hire, platform billing, and archive approval. A shared device lists only
  active staff members assigned to its configured venue.

## Service and order flow

### Agreed

- Dine-in, takeaway/collection, delivery, and bar tabs are in scope. `Takeaway`
  and `collection` are alternative labels for the same service type.
- An order can be opened against a table number or a temporary customer/tab
  name. Tables are initially a simple list; graphical floor plans are later.
- Standard numbered tables and named tabs are both supported. A named tab must
  be unique among currently open tabs/orders at the same venue; a second open
  tab with the same name is rejected. Seat assignment is not implied merely by
  using a table or named tab and is not part of the pilot.
- Seat numbers are not required. A regular customer may have an open named tab
  without any table. Before opening a named tab, the app checks all open named
  tabs in that venue and rejects an exact duplicate with a clear message.
- The POS manages reservations. The initial booking view is a calendar linked
  to standard numbered tables: staff assign a table to a named customer, with
  or without a configurable booking deposit. A future visual floor plan adds
  table capacity, free/occupied state, stage/area landmarks, and drag/drop
  layout; it must not alter historic booking/order facts.
- The basic booking calendar follows core POS/payment/printing rather than
  delaying the Spice Garden core pilot. Its fields are customer name, date/time,
  expected duration, party size, phone, and notes. Email capture and automated
  booking confirmations/cancellation replies are later features.
- Initial booking states are `requested`, `confirmed`, `arrived`, `cancelled`,
  and `no-show`. A manager alone may refund, transfer, apply, or forfeit a
  booking deposit. Staff may explicitly confirm that same-named bookings belong
  to the same customer; otherwise same names remain distinct booking records.
- A customer may not have more than one simultaneously open booking. When the
  customer attends, the booking deposit transfers to the selected final bill as
  an explicit negative booking-deposit credit, preserving the payment link and
  audit trail. A manager refund requires a reason and produces a refund receipt.
- When a booking with a deposit is cancelled or becomes a no-show, a manager may
  refund it, forfeit it, or transfer it to a new booking date. Each decision is
  separately audited and preserves the original deposit/payment trail.
- If a booking-deposit credit exceeds the selected final bill, a manager chooses
  and audits whether the surplus remains as a customer deposit credit or is
  refunded through the original tender method/currency.
- A venue configures its minimum time/buffer between bookings and/or a table
  booking schedule. A booking that conflicts with that table's available time
  is blocked rather than silently double-booked.
- The booking buffer is applied after the booking only.
- Booking customer phone is optional. The app warns staff about likely duplicate
  names/bookings, but leaves the staff member to confirm identity rather than
  blocking different customers who share a name.
- Managers may add, rename, or remove standard tables. A rename updates the
  live table and future booking display while historic ticket/receipt snapshots
  remain unchanged. Removing a table with affected future bookings requires an
  explicit reassignment to an available non-conflicting table; otherwise the
  removal is blocked. Active orders retain their stable table identity until
  moved/closed.
- Tables/orders can move, merge, and have several open orders. A paid bill is
  never reopened: further spending creates a new order/bill.
- Waiter/cashier users may move tables and merge eligible open orders without a
  manager PIN; each operation records the before/after table/order links,
  actor, timestamp, and reason where relevant.
- Cover counts/capacity and table areas are not initial requirements.
- Products use courses (drinks, starters, mains, desserts) and send to
  production immediately by default.
- Kitchen/bar staff and managers use a live **Order Flow Board** (the initial
  kitchen display/KDS) showing all current orders and item/course status:
  pending/new, preparing, ready, collected, served, cancelled, and delayed.
  It shows elapsed time from each ticket release, venue-configured amber/red
  thresholds, table/name/order reference, relevant item notes/allergy alerts,
  and production area. Red late orders visibly call attention to work that
  needs chasing; managers can use the same board to understand bottlenecks.
  The board has kitchen/bar-safe data only and no prices/customer phone numbers.
  Waiters receive ready notifications.
- A ready notification goes to the staff member who created the order and to
  any currently signed-in venue staff with waiter/cashier permission.
- Notes are needed at item level.
- Open tabs roll over automatically without a maximum age or warning. Historic
  activity remains auditable; the back office must offer a way to find and
  resolve long-running tabs without altering their history.
- Named customer tabs are required; customer telephone/email is not initially
  required.
- Course-release policy is configurable per restaurant. Orders send immediately
  by default, but a restaurant may wait for a preceding course to be collected
  or served before releasing the next ticket.
- When course-release mode is enabled, the venue selects the release condition:
  prior course `collected`, prior course `served`, or an explicit staff manual
  release. This applies independently of the normal default immediate-send
  setting.
- A held-course item reserves its stock when added to the order and formally
  decrements it when the course is released/printed. This prevents a customer’s
  already-chosen later course being sold out before production receives it.
- Any operational user may cancel an already printed item. The cancellation
  must be an audit event and production must receive a cancellation ticket.
- Kitchen tickets display every available identifier: table, customer/tab name,
  and order number; seat numbers are not used.
- Kitchen/bar tickets omit prices, payments, and customer telephone details.
  They show the table/name, order reference, line items, modifiers, free-text
  notes, and staff member who placed the order.
- Adding items to an already-sent order prints only those new items to the
  relevant production area. The ticket clearly identifies the existing order
  (table/name and order reference); a complete ticket is printed only through
  the audited `REPRINT` action.
- Item notes carry allergy information initially. Staff can additionally mark
  an item note as an **allergy alert**; the alert is prominent in the POS and
  on every relevant production ticket, without pretending to provide structured
  allergen/ingredient analysis. Configurable amber/red order timer thresholds
  are mandatory per restaurant/production area.
- Initial production states are `new`, `preparing`, `ready`, `collected`,
  `served`, `cancelled`, and `voided`. `Delayed` is a visible independent flag,
  so an item may be both `preparing` and delayed. Multiple operational roles
  may move a normal item forward through its state sequence; a manager may
  override a state only with an audit reason.
- Initial default timer thresholds are amber at 15 minutes and red at 25
  minutes; venues/production areas can configure them.
- Each item/course timer starts when its production ticket is released/printed,
  rather than when the entire table order was opened.
- Takeaway/collection and delivery orders support customer phone, collection
  time, delivery address, and driver assignment. Third-party driver
  integrations are not in scope initially.
- Customer phone is mandatory for delivery and optional for takeaway/collection.
  A delivery driver is an active venue staff member assigned through a delivery
  permission/custom role, not free-text attribution.
- Takeaway/delivery can be scheduled for a future collection/delivery time and
  supports a manager-configured manual delivery fee. The delivery fee has its
  own configurable tax category/rate, just like a product. Any role with the
  appropriate delivery-status permission may mark an order delivered.
- The default business-day cut-off for a new venue is 04:00 local venue time.
  A venue manager's later cut-off change applies from the next business day;
  past reports stay classified by the already-effective cut-off.
- The initial Order Flow Board filters by production area, status, delayed/late
  condition, and allergy alert. Advanced throughput analytics and further KDS
  workflow features may follow after the pilot.

### Deferred service extensions

- Third-party delivery-provider integrations and expanded customer contact
  workflows are later features. The core state machine and venue-configurable
  course release rules above are the pilot contract.

## Menu, modifiers, and stock

### Agreed

- Menu sections are configurable per venue. A product can appear in many
  sections.
- Managers can import/export menu setup through a validated CSV template to
  speed large venue onboarding. Imports present validation errors and a preview
  before committing; they never alter closed order/bill snapshots.
- Item options are reusable modifier groups assigned to products: examples are
  ice/no ice, steak temperature, and curry spice level.
- A modifier group needs selection rules (optional/required, minimum/maximum,
  single/multiple choice), option price changes, printable preparation notes,
  and a snapshot on the order line.
- A product can require completion of a modifier group before it can be added
  to an order (for example steak cooking preference). Modifier options may add
  or subtract money. Product production routing remains the source of the
  ticket destination; modifier-specific routing is not initially required.
- Each sellable product or variant has one default production area. A set menu
  produces its selected starter/main/side component fulfilment lines, each of
  which routes independently using that component's production area.
- A product may allow a free-text item note, in addition to selected modifier
  options. Dietary labels, ingredients, calories, and structured allergen
  information are not first-release requirements.
- Products support separately priced variants (for example glass/bottle and
  small/large). Set menus, bundles, and meal deals are required in the first
  release. Booking deposits are a separate booking-payment/credit feature, not
  menu lines or general bill partial payments.
- Initial stock tracks finished products only. Entering a tracked product sets
  its starting stock. Only owner/manager permissions may add stock or make a
  stock adjustment, and every adjustment has an audit reason. Supplier
  management, deliveries, wastage, purchase orders, and low-stock alerts are
  later features.
- Managers have a stocktake screen to enter physical counts. Applying a
  stocktake creates a reasoned, auditable adjustment from current system stock
  to the accepted physical count; it does not silently overwrite history.
- Stock is reserved/decremented when an item is sent to production, rather than
  only when its bill is paid. Cancelling before preparation restores the
  reservation automatically; after preparation a manager must choose and audit
  the stock outcome.
- Finished-product stock supports decimal quantities. The model must retain a
  unit of measure so a later ingredient/recipe feature can track measures such
  as centilitres and litres without migrating historic stock records; that
  ingredient-level feature is not part of the pilot.
- A manager can mark a product unavailable, which removes it from normal sale.
  At zero stock the product shows as sold out; an authorised manager may make an
  explicit, audited override sale rather than silently going negative.
- A manager may also make an explicit, audited override sale for an item made
  unavailable by its schedule.
- Product photos are later work, not a first-release requirement. Availability
  schedules follow the configured venue/service-type, section, and product
  inheritance/override rules described above.
- A set menu/bundle is recorded as its own sale line for menu/reporting
  purposes, while its selected component products each reduce their individual
  finished-product stock. Set-menu choice groups support requirements such as
  one starter, one main, and one side, including configured upgrade prices.
- For a set meal containing items with different tax categories (for example
  food and alcohol), the venue explicitly sets an inclusive taxable value for
  each component. Those allocated values must add exactly to the advertised set
  price and are snapshotted on sale. This lets a restaurant retain alcohol at
  its ordinary value while applying any deal discount to food, instead of using
  an arbitrary tax allocation.
- A product's own availability schedule overrides its section schedule.
- After a prepared-item cancellation, a manager may restore stock, record it
  as non-restored wastage, or set a custom resulting stock quantity. The choice
  and required reason are audited.
- A later financial refund does not change stock automatically. Stock changes
  only through an explicit manager adjustment with its own audit reason.
- A venue may override a product's price, tax category, availability, and
  future recipe while inheriting every other company product field. Recipe/
  ingredient stock is not active in the first release.

### Deferred inventory

- Recipe/ingredient stock and supplier purchasing are later features; the
  decimal-unit foundation avoids a future migration of pilot stock history.

## Printing, QR, reporting, and release

### Agreed

- Native Android/Windows devices listen to a trusted cloud print queue and
  print only their assigned jobs. Print routing separates bar, kitchen,
  dessert, and receipt workflows.
- The first pilot uses Android terminals with integrated thermal printers. A
  lightweight Android print-agent will be designed for Android 7/API 24,
  assigned printer/device credentials only, vendor printer SDK integration,
  automatic retry, and fallback routing. It must not receive ordinary staff
  or financial permissions.
- Printed reissues must say `REPRINT` and include the original ticket/order
  reference; the reprint actor and reason are audit events.
- Future QR customer ordering/payment is browser-first; orders can require
  staff approval before printing.
- Sales reporting uses closed bills and the venue's local business day. Tabs
  may continue across days according to a future rollover policy.
- First reports are daily, weekly, and monthly sales. CSV is the first export
  format. Required views include gross/net sales, tax, payment method, product,
  staff, open tabs, voids/cancellations, and stock.
- Each bill captures both the staff member who created the order and the staff
  member who completed payment. Staff sales reports can show both attributions.
- A manager configures the venue business-day cut-off time to support
  late-night venues. A cut-off change is audited; the historical-effective-date
  policy is prospective-only so closed sales are never silently reclassified.
- Owners and managers may view/export reports. A direct user permission may
  additionally grant reporting/export access to another staff member.
- SaaS charging is per venue, with an optional terminal-hire charge. A trial
  lasts 30 days and begins when the company is created. Only the full platform
  administrator may grant a temporary
  access override. An unpaid company receives a payment message and 30-day
  grace period, then is blocked until payment is restored; its data remains
  intact. While blocked, company users may not view or export historic reports.
- A native device may continue using its last successfully verified entitlement
  for the duration of a genuine internet outage; it rechecks immediately when
  connectivity returns and then enforces the current subscription state. This
  supports venues with unreliable connectivity while preserving server-side
  enforcement once the service is reachable.
- SaaS feature entitlements are optional modules (such as KDS, QR ordering, QR
  payment, stock, extra venues, and terminal hire) rather than fixed permanent
  packages. Pricing/billing stays configurable by the platform administrator.
- Terminal hire is a monthly per-physical-device add-on; customers may instead
  buy a supported device.
- Billing begins with platform-admin manual invoice creation and manual
  paid-status marking. Marking a qualifying invoice paid immediately restores a
  blocked company. Stripe recurring subscription/payment automation is a later
  integration.
- A manual invoice records invoice number, issue date, due date, company and
  venue, subscribed plan/add-ons, currency, amount, tax, and payment status.
- Each company has a platform-admin-controlled SaaS billing currency, separate
  from restaurant reporting/trading currencies. It is locked for issued
  invoices and must be changed by the platform administrator before a future
  invoice is raised.
- Company owners can view/download their invoices and see payment status;
  platform administrators alone mark a manual invoice paid.
- The platform uses separate Firebase development, staging, and production
  projects, daily full backups, frequent incremental backups, and documented
  export/restore procedures.
- App UI language is an account-level setting, defaulting to English. English,
  Turkish, and Greek are launch languages; the translation model supports more
  languages later. Product/menu translation is a separate later feature from
  app-interface language.
- The platform admin dashboard must show device health/online status, printer
  failures, print-queue backlog, subscription state, and support-session audit
  history.
- Customer, booking, sales, deposit, and operational data has no automatic
  deletion period. It is retained until an authorised deletion policy/action is
  chosen, subject to a later country-specific tax/privacy retention review.
- The initial pilot target is three months from discovery: 20 November 2026.
- The pilot is Spice Garden, using two Android 14 handheld terminals with
  integrated 58 mm printers; waiters use phones. These terminals must support
  full POS operation as well as assigned print functions, although larger
  displays may be preferred for back-office tasks.
- Terminal setup selects `full POS + printer` or a restricted `printer-only`
  mode. Print-agent auto-start after reboot is required where supported by the
  terminal/Android vendor. Kiosk mode is not required.
- Print failures raise every available appropriate alert: in-app message,
  sound, vibration, and native notification. Managers alone configure fallback
  printers. A job retries its original printer three times, ten seconds apart,
  before trying its configured fallback.
- Printer routes, fallback chains, and device/printer assignments are venue
  configuration. They are never tied to the staff member who signs in. When a
  staff member switches venue, the full POS loads that venue's routing; a
  printer-only device is assigned/reassigned by a manager and processes only
  the venue it is currently authorised for.
- Every kitchen/bar/dessert/receipt route has one primary printer and an ordered
  fallback chain. It prints one copy by default; managers can configure the
  copy count for a route. The existing retry policy applies before advancing to
  the next fallback.
- Venue printer diagnostics provide a test-print action, online/offline and
  paper/error state where the vendor SDK exposes it, last successful print,
  pending/failed job history, retries, and fallback outcome.
- Candidate terminal specification: Android 14/11, octa-core 2.0 GHz, 5.5 in
  1440x720 touch display, integrated 58 mm thermal printer (80 mm/s), optional
  NFC and 1D/2D scanner, 4G/Wi-Fi, and removable battery. Buy the 3 GB RAM /
  32 GB storage model for a full-POS terminal; 1 GB / 8 GB is unsuitable for a
  supported POS deployment. Before ordering, confirm the actual Android image,
  ARM ABI, vendor printer/scanner/NFC SDK, Google Play Services availability,
  and reboot/background-start behaviour in writing from the supplier.

### Procurement and deferred integrations

- Before terminal procurement, validate the named supplier’s actual printer,
  scanner/NFC, architecture, Android image, and reboot/background behaviour.
  The agreed print retry/fallback/reprint policy is already fixed.
- KDS, QR payment/provider selection, and hardware beyond the pilot terminal
  are deliberate later releases. Development/staging/production environments
  and backup/restore requirements are already fixed above.

### Offline and local-network policy

- Every native POS client must show a clear offline state and safely queue its
  own writes for Firebase synchronisation when connectivity returns.
- If a waiter device is offline and has no attached local printer, it keeps the
  order durably as `pending sync — not sent to kitchen/bar` and immediately
  alerts the user; it must never imply that production has received it.
- If an offline device has an assigned local printer, it may print its own
  durable order ticket locally. It must retain an idempotency key so a later
  cloud synchronisation cannot duplicate that ticket.
- Sending orders from one offline device to another device over venue Wi-Fi is
  **not** a simple peer-to-peer feature. It requires a trusted, authenticated,
  encrypted local relay/hub with durable storage, conflict handling, and a
  reconciliation protocol. Whether that is needed for the pilot is open; it
  must be a separately tested phase rather than a shortcut around financial or
  production records.
- Cross-device offline ordering/printing is a later feature. The pilot scope is
  safe local offline ordering/printing on the originating device, followed by
  Firestore synchronisation when connectivity returns.
- A printer failure produces an alert on every currently connected device in
  that venue, as well as on the device detecting it. During an internet outage,
  cross-device alerts cannot be guaranteed until connectivity returns, but the
  originating device continues to show the immediate local failure/pending-send
  state.
- An operational recovery screen lists unsent offline orders, failed/pending
  print jobs, incomplete payment attempts, and reconciliation warnings. Staff
  can see the exact state and authorised next action; recovery actions retain
  idempotency and audit history.

## Customer QR channel

- The customer channel is a separate browser-based website, not an installed
  app. The customer scans a venue/table QR code, sees the menu, selects food
  and drink, and submits an order proposal without payment.
- QR codes can remain physically printed at tables but use a random public
  token rather than a raw table ID. A restaurant may rotate/revoke a code for
  security; old codes become invalid. A closed venue returns a clear
  `restaurant is not open` message.
- Customer proposals require staff approval. Staff select an existing or new
  bill and may reassign it to the relevant table, approve it, or decline it.
  The normal order/production workflow then creates tickets and attaches the
  items to that bill. The customer can see live accepted/preparing/ready status
  after approval.
- A pending QR order proposal expires automatically after 15 minutes if staff
  do not approve it.
- A QR customer cannot cancel a submitted proposal; it remains pending until
  approved, declined, or automatically expires.
- QR customers follow exactly the staff ordering availability and stock rules,
  including service-type schedules, product/section schedules, sold-out state,
  required modifiers, and free-text notes.
- QR customers use the same required variants/modifiers and free-text notes as
  staff. This prevents unambiguous production choices (such as steak cooking
  preference) being lost between customer order and kitchen ticket.
- Calling a waiter, water requests, QR payment, customer split payment, and
  third-party delivery/takeaway apps are later features. QR payment provider
  selection is Stripe and/or PayPal rather than Card Plus; the integration must
  remain configurable. Structured customer allergen information is a later
  feature; item notes are the initial allergy mechanism.
- The first QR site is English only. A declined proposal simply tells the
  customer `Please speak to staff`; it exposes no internal reason. The live
  status page becomes unavailable immediately when its linked bill closes.

## Delivery phases

1. **Foundation:** tenancy, memberships, support mode, venue inheritance,
   audited permissions, tax/currency model, environments, and automated tests.
2. **Operations:** venue menu, modifiers, tables/named tabs, order lifecycle,
   kitchen/bar routing, device registration, and resilient print queue.
3. **Billing:** immutable bills, tax calculation, split/mixed tenders, cash-up,
   foreign tender/exchange-rate audit, refunds, and business-day close.
4. **Bookings and management:** booking calendar/deposits, stock, reports,
   exports, staff management, printer/device health, and SaaS subscription
   enforcement.
5. **Customer channels:** following the basic booking calendar, secure QR
   sessions, approval workflow, online
   ordering, customer payment, and provider integrations.

Each phase gets a security review, Firestore rules review, migration plan,
responsive UI acceptance criteria, test suite, and pilot checklist before the
next phase begins.

## Build architecture

### Client applications

- One responsive Flutter application serves Android, Windows, web, and iOS.
  Riverpod owns application state, with repositories isolating Firebase, native
  printing, local persistence, and platform APIs from UI code.
- Screen layout uses compact handset, medium tablet, and expanded desktop
  breakpoints. Capabilities are permission-gated, never hidden merely because
  of screen size.
- Native Android/Windows modules provide printer discovery/SDK access, durable
  print processing, reboot recovery where the OS/vendor permits it, and local
  offline print storage. Web/iOS never claim native printer-agent jobs.

### Firebase services

- Firebase Authentication holds email/password identities only. Company/venue
  memberships, roles, PIN-verification metadata, device enrolment, and
  entitlements live in Firestore and are enforced by callable Cloud Functions
  plus Firestore rules.
- Cloud Firestore is the source of truth for tenant configuration, menu,
  orders, bills, bookings, devices, print jobs, audit events, and SaaS records.
  Every document is scoped by company and, where operational, venue.
- Cloud Functions perform privileged actions: platform administration,
  membership invitations, PIN reset/unlock, support mode, finalising bills,
  payment/refund recording, stock mutations, invoice status changes, and print
  job creation. The client never writes a privileged financial/audit result
  directly.
- Cloud Storage holds company/venue logos and future product images. Storage
  rules require the same company/venue membership checks as Firestore.
- Development, staging, and production use separate Firebase projects and
  separate configuration. No production identifier or secret is bundled into a
  development build.

### Tenant-safe Firestore shape

```text
platformAdmins/{uid}
users/{uid}                              # profile, language, safe preferences
companies/{companyId}                    # legal/default/reporting details
companies/{companyId}/venues/{venueId}   # trading currency, timezone, hours
companies/{companyId}/memberships/{uid}  # role(s), venue access, lifecycle
companies/{companyId}/roles/{roleId}     # permission templates
companies/{companyId}/taxCategories/{id}
companies/{companyId}/taxRateVersions/{id}
companies/{companyId}/menu/...           # inherited company defaults
companies/{companyId}/venues/{venueId}/menuOverrides/...
companies/{companyId}/venues/{venueId}/tables/{tableId}
companies/{companyId}/venues/{venueId}/bookings/{bookingId}
companies/{companyId}/venues/{venueId}/orders/{orderId}
companies/{companyId}/venues/{venueId}/bills/{billId}
companies/{companyId}/venues/{venueId}/payments/{paymentId}
companies/{companyId}/venues/{venueId}/stock/{productId}
companies/{companyId}/venues/{venueId}/devices/{deviceId}
companies/{companyId}/venues/{venueId}/printers/{printerId}
companies/{companyId}/venues/{venueId}/printJobs/{jobId}
companies/{companyId}/auditEvents/{eventId}
companies/{companyId}/invoices/{invoiceId}
```

Closed financial documents contain full immutable snapshots rather than relying
on live product, tax, venue, user, or printer records. A write carries an
idempotency key, actor/device context, and server timestamp so retries cannot
create double payments, duplicate tickets, or duplicated stock movement.

### Security boundaries

- Firestore and Storage rules default-deny. Every read/write confirms active
  membership, company, venue, role permission, and subscription/support state.
- Financial close/refund/void, stock adjustment, PIN unlock/reset, company
  archive/restore, invoice paid status, and support write mode are server-side
  commands that verify a fresh identity/PIN where required.
- Role permissions are evaluated server-side; hiding an interface control is
  never treated as access control.
- Audit events are append-only. The actor cannot alter or delete an audit event.
- Public QR requests use opaque rotating tokens, rate limits, server validation,
  short pending expiry, and no direct public access to private orders/bills.

## Screen and workflow map

1. **Sign-in and venue selection** — email/password, company/venue selector,
   language choice, personal-device session; shared-terminal staff selector and
   PIN lock screen.
2. **POS service** — table/named-tab selector, category/product grid, modifier
   sheet, item notes, course release, order timeline, move/merge/split, draft
   bill, payment, and receipt actions.
3. **Order Flow Board** — live kitchen/bar/manager board, timers, amber/red
   overdue state, filters, status updates, ready notifications, and
   cancellation/reprint traces; no prices or customer phone numbers.
4. **Bookings** — numbered-table calendar, table availability/buffer checks,
   named booking, deposit payment/credit/refund/forfeit/transfer workflow.
5. **Menu and stock** — sections, products, variants, modifier groups, tax and
   production route assignment, schedules, set-menu component allocation,
   stock/unavailable controls, and audited adjustments.
6. **Venue administration** — inherited company values, local overrides,
   timezone, opening hours, business-day cut-off, tables, routes/printers,
   terminals/devices, card-terminal list, staff and roles. A first-service
   onboarding checklist validates tax rates, menu, tables, printer routes,
   card terminals, staff roles, and a successful test print before the venue is
   marked ready.
7. **Reports** — daily/weekly/monthly closed-bill reporting by business day;
   gross/net/tax, tender currency, product, order creator/payment taker, open
   tabs, cancellations/voids, booking deposits, and stock.
   It includes daily-close snapshots and card-terminal reconciliation.
8. **Platform administration** — companies, support mode, archive/restore,
   invoices/entitlements, terminal hire, platform health and audit history.

## Pilot scope and release sequence

### Spice Garden core pilot — required by 20 November 2026

- Multi-company/venue identity, roles, audited support mode, responsive Flutter
  UI, language settings, controlled timezone/currency setup, and safe logging.
- Venue/company inheritance, menu sections/products/variants/modifiers,
  production areas, service schedules, tax configuration, tables/named tabs.
- Validated menu CSV import/export, setup templates, price schedules, and a
  first-service onboarding checklist with printer test are core requirements.
- Dine-in, takeaway/collection, delivery, and bar-tab ordering; immediate or
  configured course release; item status, timers, notes, moves, merges, and
  repeatable bill splits.
- Android integrated-printer operation, venue printer routing, primary/fallback
  chain, three retries at ten seconds, reprints/cancellations, local offline
  safety, and connected-device print alerts.
- Live Order Flow Board for kitchen/bar/manager use, with ticket-release timers,
  configurable amber/red late thresholds, order-status updates, production-area
  and allergy/late filters, and ready notifications.
- Manual Card Plus terminal selection, cash/foreign-cash tenders, immutable
  closed bills, card refunds after terminal completion, draft/standard receipts,
  business-day reporting, daily-close snapshots, terminal reconciliation,
  audit trail, and finished-product stock.
- Stocktake, prominent allergy-alert notes, printer diagnostics, and the
  operational recovery screen are core requirements, not later enhancements.
- Daily/weekly/monthly on-screen reports with the agreed breakdowns.

### Release immediately after stable core

- Booking calendar and booking deposits; manual SaaS invoices, entitlements and
  subscription blocking; enhanced printer/device health; full staff
  administration and role editor where not required for core setup.

### Deliberately later releases

- Public staff-approved QR ordering, then QR payment with configurable
  Stripe/PayPal; advanced order-flow analytics; vouchers; integrated Card Plus;
  online billing; ingredient/recipe stock; graphical floor plan; delivery
  marketplace integrations; customer booking site; customer menu translations;
  email/digital receipts; and local-network cross-device offline relay.

## Quality gates and pilot acceptance

- Unit tests cover tax-inclusive arithmetic, tax snapshots, set-menu component
  allocation, split-bill rounding, FX recording, stock reservations, schedule
  evaluation, state transitions, permission decisions, and invoice entitlement.
- Integration tests prove tenant isolation, invitation/existing-user membership,
  owner protection, PIN locking/unlocking, offline queue idempotency, print-job
  retries/fallbacks, and financial corrections.
- Device tests use the actual 3 GB/32 GB Android terminal before procurement is
  final: vendor SDK print, paper-out/error conditions, reboot behaviour,
  background restrictions, scanner/NFC claims, Wi-Fi loss, and battery use.
- Pilot rehearsal covers a full shift: dine-in, named tab, course hold, split
  bill, mixed tender, foreign cash, void/cancellation, refund, stock override,
  printer failure/fallback, reconnect after outage, day cut-off, and report
  reconciliation.
- Production release requires rule review, least-privilege service accounts,
  backup/restore rehearsal, privacy/tax review for each supported jurisdiction,
  zero unresolved critical security defects, and a documented rollback plan.
