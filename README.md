# TableSide POS

An adaptive Flutter foundation for a multi-restaurant restaurant POS. It targets Android, iOS, web, and Windows, uses Riverpod for UI state, and is structured to use Firebase Authentication, Cloud Firestore, and Cloud Storage.

The starter deliberately runs with local demo data before Firebase has been configured. This makes it safe to review the responsive POS workflow first; the repository classes and deployment files describe the production connection points.

## What is included

- A responsive POS: a three-panel desktop layout at 1100px+, and a compact table/menu/order layout below that.
- Tenant-aware organisation profile controls, including a cross-platform image picker for a company logo.
- Menu sections and products, including products that belong to multiple sections and route to a bar or kitchen production area.
- Riverpod controllers for menu category, table selection, open order lines, and the tenant profile.
- A print-worker contract for Android/Windows printer devices, plus its Firestore index and initial security rules.
- Menu, daily-sales, open-tab, settings, and split-bill UI foundations.

## Recommended data model

All tenant data lives beneath an immutable tenant boundary. Never put a tenant ID in a mutable client-side preference and trust it: derive the active tenant from a signed-in user's membership.

```text
tenants/{tenantId}
  members/{uid}                  userId, roles: [owner, manager, waiter, printer]
  venues/{venueId}               timezone, business-day cutoff, address
  menuSections/{sectionId}       name, sortOrder, active
  products/{productId}           sectionIds[], priceMinor, productionArea, stockMode
  tables/{tableId}               label, area, seats, currentOrderId
  orders/{orderId}               status, tableId, openedBusinessDate, source
  bills/{billId}                 orderId, allocations, payments, closedBusinessDate
  paymentRequests/{requestId}    billId, amountMinor, method, status, idempotencyKey
  printJobs/{jobId}              targetDeviceId, status, payload, idempotencyKey
  devices/{deviceId}             platform, venueId, printer profile, lastHeartbeat
```

Use integer minor units (`priceMinor`) for every money value; never store prices as floating point. Order lines must contain immutable snapshots of the product name, tax rate, unit price, and production area, so later menu changes do not change a historical bill.

### Currency and foreign tender

`tenants/{tenantId}.currencyCode` is the restaurant's **functional currency**: menu prices, tax, bills, and daily sales reporting use it. It is not the currency a guest happens to tender. It is selected when the restaurant is created and is then permanent. This avoids a concurrent menu change or a later price record being silently reinterpreted in another currency; create a new restaurant company for a separate trading currency instead.

Every payment request already records the bill's `currencyCode`; it is validated against its restaurant's functional currency. When multi-currency payments are implemented, each bill must snapshot `billCurrencyCode`. Each payment/tender must separately record `tenderCurrencyCode`, `tenderAmountMinor`, `functionalAmountMinor`, the locked exchange rate, rate source (for example terminal quote or manager-approved cash rate), and timestamp. Reports should aggregate `functionalAmountMinor` while retaining foreign-tender totals for reconciliation. Never recalculate a historic payment with a newer exchange rate or overwrite a bill's currency.

### Multi-venue and company branding

A tenant represents a restaurant company. A venue is one physical restaurant beneath it. Store the logo and legal/trading details at `tenants/{tenantId}`; then copy them into a closed receipt snapshot. This allows the company profile to change without altering a past receipt, and lets each venue provide its own address, tax registration, and printer routing.

`TenantProfileRepository` uploads branding to:

```text
tenants/{tenantId}/branding/{timestamp}-{fileName}
```

The supplied storage rules limit this to authenticated tenant members and image files below 2 MB.

### Bills, tabs, and business-day rollover

Keep the order open until all of its bill allocations are paid or written off. To split a bill, create one or more `bills` documents that each reference specific line quantities or a proportional allocation; validate on the server that allocations never exceed the original ordered quantity.

An open tab should retain `openedBusinessDate` and be visible in an aged-tabs report. When it is closed, set `closedBusinessDate` to the current venue business day. Daily sales reports aggregate **closed bills by `closedBusinessDate`**, not by the original order date. That makes overnight and multi-day tabs auditable while preserving the intended daily revenue report.

### Stock

`stockMode` should be `none`, `product`, or `recipe`. For the first release, product-level stock is enough. On a server-validated order transition (usually `sent` or `closed`, depending on the restaurant policy), add an immutable stock movement instead of only decrementing a counter:

```text
stockMovements/{movementId}: productId, delta, reason, orderId, occurredAt
```

The current on-hand value can be maintained by a Cloud Function transaction, but the movement log is the source of truth for reconciliation and corrections.

## Native print-worker design

This is the recommended approach for your Android/Windows-only physical printers:

1. A waiter sends an `orderEvent` with only the newly approved lines.
2. A trusted Cloud Function maps each line's `productionArea` to a venue printer route, then creates one deterministic `printJobs` document per target device.
3. The Android/Windows app signed in as that registered device queries only its queued jobs.
4. It claims a job in a Firestore transaction, prints it through the platform printer integration, then marks it `printed` or `failed`.
5. Retries use the job's `idempotencyKey`; a device must never print that key twice without an explicit reprint action.

Use a deterministic ID such as `{orderId}_{eventId}_{deviceId}` for server-created jobs. This prevents duplicate tickets when a function retries. A background worker should also abandon stale `claimed` jobs after a timeout and return them to `queued`.

Do **not** let a web client directly write a completed print job, and do not make a printer device responsible for routing. Routing, prices, discounts, stock, and payments belong in trusted Cloud Functions or a server API. The provided `PrintJobRepository` is the native client-side claim/acknowledge portion; job creation should be server-only.

`NativePrintWorker` is now the platform-neutral worker loop. Implement `NativeReceiptPrinter` separately for the printer protocol you deploy; the app deliberately does not pretend USB and Bluetooth APIs are portable across Android and Windows. Register each device through `PrinterDeviceRepository`, issue a device-specific custom claim from a trusted server, and only then start the worker for that device.

## Payments

The app now creates a `paymentRequests` document rather than changing a bill from the client. A Cloud Function must load and validate the bill, enforce the remaining balance, use the request's idempotency key with the selected payment provider, and only then write the payment and close the bill.

This is intentionally provider-neutral: choose a provider that supports your countries, currencies, and physical terminal hardware before implementation. Common choices have materially different onboarding, terminal, offline, and refund flows, so no real money movement is enabled by this starter.

## Future customer QR ordering

Customer orders should use a separate public session, for example `tableSessions/{publicToken}`, rather than exposing a raw table ID in a QR code. The public service writes a customer order as `pendingApproval`; it must not create print jobs or commit stock. A waiter accepts/rejects it in this app. Acceptance creates the normal order event, which then releases the appropriate bar/kitchen tickets.

This means the customer app can be built later without changing the core order, bill, stock, or print model.

## Firebase setup

1. This repository is connected to the Firebase project `table-pos`. In the Firebase Console, enable **Email/Password** in Authentication, Cloud Firestore, and Storage.
2. The generated [`lib/firebase_options.dart`](lib/firebase_options.dart) contains the public, platform-specific app identifiers for Android, iOS, web, and Windows. Regenerate it whenever an app or Firebase product is added:

```powershell
flutterfire configure --project table-pos --platforms android,ios,web,windows
```

The default remains demo mode. To use Firebase, only enable the mode flag; no API keys or app IDs need to be supplied manually:

```powershell
flutter run -d windows --dart-define=TABLESIDE_USE_FIREBASE=true
```

3. Install the Firebase CLI, select your project, and deploy the supplied rules, indexes, Storage rules, and the platform-administration functions:

```powershell
firebase use table-pos
cd functions
npm install
cd ..
firebase deploy --only functions,firestore:rules,firestore:indexes,storage
```

The first deployment prompts for `INITIAL_PLATFORM_ADMIN_EMAIL`. Enter the email address for your own Firebase Authentication account. The CLI stores that deployment value in `functions/.env.table-pos`; it is deliberately ignored by Git.

4. Sign in to the app with that account in Firebase mode. Because it has no restaurant membership yet, it displays **Set up the initial platform admin**. Press it once. The server verifies the configured email, grants the `platformAdmin` custom claim, and the app refreshes the sign-in token.

5. The new **Platform** section then lets that super user:

- create an email/password staff account;
- send its password-reset email, so the staff member chooses their own password;
- select any existing Firebase Auth account as a restaurant company owner;
- create the restaurant company and its first venue; and
- assign an existing account an owner, manager, waiter, or printer-device role for a restaurant.

The platform role is deliberately **not** Firebase-project Owner access. It has comprehensive TableSide data access while Firebase project administration, billing, and server credentials remain outside the app. User creation, Auth-user listing, membership assignment, tenant creation, and platform-admin promotion run only in authenticated Cloud Functions using the Firebase Admin SDK. This avoids a client being able to give itself privileges.

Cloud Functions deployment requires the Firebase project to be on the Blaze plan. The functions are configured for Node.js 22 and `europe-west2` (London), alongside the existing Firestore and Storage location.

The deployed rules prevent staff from changing their own roles, and restrict profile/image changes to owners and managers. Production order updates must still be limited to safe state transitions, while payment and stock mutations remain server-only.

### App Check rollout

App Check is activated during Firebase startup before the app uses Authentication, Firestore, or Storage:

- Android debug/profile builds use Firebase's debug provider, which works on the Android 7.1 pilot device.
- Android release builds use Play Integrity. For an APK distributed outside Google Play, configure the Play Integrity App Check registration as an outside-Google-Play app and do not require the `PLAY_RECOGNIZED` or `LICENSED` verdicts.
- iOS debug builds use the debug provider; release builds use App Attest with DeviceCheck fallback. Register the iOS bundle in App Check before testing a signed iPhone build.
- Windows has only Firebase's debug provider. It is supported for development/monitoring, but is not suitable as a production attestation secret because a shipped desktop app can be inspected. Windows remains protected by sign-in, membership checks, Firestore/Storage rules, and server-side validation; do **not** enable Firebase service enforcement until a production desktop approach is agreed.
- Web debug builds use the debug provider. Supply a registered `TABLESIDE_WEB_APP_CHECK_DEBUG_TOKEN` to keep one development browser token stable; otherwise Firebase generates one per browser origin. Production web builds use reCAPTCHA v3 when supplied a registered site key through `TABLESIDE_WEB_APP_CHECK_RECAPTCHA_SITE_KEY`.

Set up Android App Check in this order:

1. In Firebase Console, open **Security → App Check**, register the Android app (`com.tableside.tableside_pos`) with Play Integrity, and follow the Firebase/Google Play Console linking steps. Add the SHA-256 certificate used to sign the APK.
2. Run a debug build on the test terminal. The Android debug provider writes an App Check debug token to the Android log. Add that token in **App Check → Apps → Manage debug tokens**. Never place a debug token in Git or a release build.
3. For web production, register a reCAPTCHA v3 provider in App Check and build with `--dart-define=TABLESIDE_WEB_APP_CHECK_RECAPTCHA_SITE_KEY=YOUR_PUBLIC_SITE_KEY`. For iOS, register the iOS app and select App Attest with DeviceCheck fallback.
4. In Google Cloud Console **IAM**, grant the Cloud Functions service account `33541448236-compute@developer.gserviceaccount.com` the **Firebase App Check Token Verifier** role. Without this role the monitor-mode APIs stay available, but their token verification will log a permission error instead of useful results.
5. Keep Firestore, Storage, Authentication, and Functions in their App Check **monitor** state. Use their metrics to confirm valid requests are arriving.
6. The custom `posApi` and `platformAdminApi` endpoints also receive and verify `X-Firebase-AppCheck` tokens, but remain monitor-only by default. After every live client is registered, set `REQUIRE_APP_CHECK=true` in `functions/.env.table-pos` and redeploy functions.
7. Only then consider enabling Firebase Console enforcement for supported services. This action rejects clients without valid attestation, so it must be tested on the real Android 7.1 hardware first.

For Windows development monitoring, create a registered debug token and run:

```powershell
flutter run -d windows --dart-define=TABLESIDE_USE_FIREBASE=true --dart-define=TABLESIDE_WINDOWS_APP_CHECK_DEBUG_TOKEN=YOUR_REGISTERED_TOKEN
```

For a stable Chrome development token, register a different debug token and run:

```powershell
flutter run -d chrome --web-port=5000 --dart-define=TABLESIDE_USE_FIREBASE=true --dart-define=TABLESIDE_WEB_APP_CHECK_DEBUG_TOKEN=YOUR_REGISTERED_TOKEN
```

## Run locally

```powershell
flutter pub get
flutter run -d windows
```

For the web target use `flutter run -d chrome`; for an Android device use `flutter devices` then select its ID. Firebase mode shows the sign-in screen, then streams the user's tenant/venue, menu, products, and tables from Firestore.

## Next implementation slice

1. Implement menu/table CRUD with role checks and Firestore emulator tests.
2. Create server functions for line snapshots, stock movements, split-bill validation, payment capture, and printer routing.
3. Select the payment provider and printer protocol, then implement the respective terminal adapter and `NativeReceiptPrinter` adapters.
4. Add device provisioning, a print retry dashboard, and end-to-end hardware tests.
