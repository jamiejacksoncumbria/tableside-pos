# Firebase environments

TableSideCY uses two completely separate Firebase projects. Never use the
production project for development or acceptance testing.

## Staging

- Firebase project: `table-pos`
- Realistic staging venue: Spice Garden
- Intended for all testing, training data, test sales, refunds, vouchers,
  customers, delivery orders, offline-hub trials and upgrade rehearsals.
- Every Firebase-backed staging build displays `STAGING · TEST DATA ONLY`.

Build or deploy staging with the root build script (staging is the default):

```powershell
.\tableside-build.ps1 -Action BuildWindows -Environment Staging
.\tableside-build.ps1 -Action BuildApk -Environment Staging
.\tableside-build.ps1 -Action DeployWeb -Environment Staging
```

For direct Flutter runs, use the committed staging definition file:

```powershell
flutter run --dart-define-from-file=config/firebase-staging.json
```

## Production

Production is deliberately disabled until a separate Firebase project exists.
Create the project and register web, Windows, Android and iOS apps. Then:

1. Copy `config/firebase-production.example.json` to
   `config/firebase-production.json`.
2. Fill it with the public identifiers emitted by FlutterFire/Firebase.
3. Keep that local file out of Git; it is already ignored.
4. Put the production Android `google-services.json` and iOS
   `GoogleService-Info.plist` in `config/firebase-production/` for the native
   release setup. Do not overwrite the committed staging files during normal
   development.
5. Deploy backend rules, indexes and Functions to the production project
   before distributing a production client.

Production commands require both `-Environment Production` and the production
configuration. Deployments additionally require typing the exact project ID.
The app rejects a production configuration that points to `table-pos`.

```powershell
.\tableside-build.ps1 -Action BuildWeb -Environment Production
.\tableside-build.ps1 -Action DeployBackend -Environment Production
```

## Promoting Spice Garden

Spice Garden remains the staging venue because it contains useful realistic
test data. Before launch, copy only reviewed configuration to a new production
company/venue:

- venue identity and operational settings;
- tables and booking rules;
- menu sections, products, variants, modifiers, tax rates and courses;
- recipes/stock components and suppliers where approved;
- printer routes as templates only (physical devices must be freshly enrolled);
- roles and permissions, followed by fresh production staff invitations.

Never copy staging sales, payments, refunds, vouchers, customers, bookings,
audit entries, print queues, PIN sessions, offline events, device enrolments or
hub certificates/epochs. Enter opening stock balances as a separate audited
production operation. This avoids a destructive one-time purge and leaves the
staging system available for every future update rehearsal.

## iOS development

Apple tooling frequently changes generated workspace files. Before switching
or pulling branches on the Mac, stash tracked and untracked changes:

```bash
git stash push -u -m "local ios generated changes"
git pull --ff-only origin test/system-testing-and-bug-fixes
flutter pub get
```

Restore only changes that are genuinely required; generated Pod/Xcode changes
should not be committed accidentally.
