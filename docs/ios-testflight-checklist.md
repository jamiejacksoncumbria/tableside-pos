# iOS and TestFlight release checklist

TableSideCY uses iOS 15 or later, bundle identifier
`uk.co.gopcpitstop.tablesideCY`, Flutter Swift Package Manager integration, and
Firebase Cloud Messaging (FCM). The checked-in `GoogleService-Info.plist`
belongs to the staging Firebase project (`table-pos`). Keep the first
TestFlight rollout internal while it uses staging.

## One-time Apple and Firebase setup

1. Join the Apple Developer Program and add `uk.co.gopcpitstop.tablesideCY`
   as an explicit App ID in Certificates, Identifiers & Profiles.
2. Enable **Push Notifications** for that App ID.
3. In Xcode, open `ios/Runner.xcworkspace`, select **Runner**, then select your
   development team under **Signing & Capabilities**. Keep **Automatically
   manage signing** enabled.
4. Confirm the Runner target shows both **Push Notifications** and
   **Background Modes**, with **Remote notifications** selected. These are
   represented in source control by the Runner entitlements and Info.plist.
5. In the Apple Developer portal, create an APNs authentication key (`.p8`)
   with Apple Push Notification service enabled. Record its Key ID and your
   Team ID. The private key can only be downloaded once; store it in a secrets
   manager and never commit it.
6. In Firebase Console for `table-pos`, open **Project settings → Cloud
   Messaging → Apple app configuration**. Upload the `.p8` key and enter the
   Key ID and Team ID for the iOS app whose bundle ID is
   `uk.co.gopcpitstop.tablesideCY`.
7. Create the TableSideCY app in App Store Connect using the same bundle ID.
   Use **Internal Testing** for the staging build.

Firebase method swizzling must remain enabled. Do not add
`FirebaseAppDelegateProxyEnabled = false` unless all APNs token forwarding is
implemented manually.

## Prepare the Mac checkout

Apple tooling can change generated files. Preserve any local Xcode changes
before updating:

```bash
cd ~/StudioProjects/tableside-pos
git stash push -u -m "local Apple generated files before update"
git fetch origin
git pull --ff-only origin main
flutter pub get
open ios/Runner.xcworkspace
```

Do not run `pod install`. The project now uses Flutter's generated Swift
packages. If this checkout previously used CocoaPods, run `pod deintegrate`
once from `ios/`, then reopen the workspace and run `flutter pub get` from the
project root.

## Build the staging TestFlight archive

Increment `version` in `pubspec.yaml` for every upload. The build number after
the `+` must always increase.

```bash
cd ~/StudioProjects/tableside-pos
flutter pub get
flutter analyze
flutter test
flutter build ipa --release \
  --dart-define-from-file=config/firebase-staging.json
```

Upload the generated archive with Xcode Organizer or Apple's Transporter.
This build deliberately displays the staging environment and must initially
be limited to internal testers.

## Notification acceptance test on a physical iPhone or iPad

Push notifications cannot be fully accepted using only the simulator. Install
the TestFlight build on a physical device, then:

1. Sign in, select a venue, select the staff member, and enter the staff PIN.
2. Accept the iOS notification permission prompt.
3. Confirm the local debug log records `Push notification device registered
   for this venue.` It must never print the FCM token.
4. Trigger an operational notification (for example, mark an assigned order
   ready or make a driver-assigned delivery ready).
5. Confirm alert, badge and sound while the app is foregrounded.
6. Repeat with the app backgrounded and then fully terminated.
7. Tap the notification and confirm TableSideCY opens, then confirm the live
   venue stream shows the current server state.
8. Sign into another staff PIN on the same shared device and confirm alerts no
   longer expose the previous staff member's assignments.
9. Revoke notification permission in iOS Settings and confirm POS operation
   still works while the notification registration fails safely.

## Production release gate

Before external TestFlight or App Store release:

- create and select the separate production Firebase iOS app and production
  `GoogleService-Info.plist`;
- build with `config/firebase-production.json` and confirm the app does not
  show the staging banner;
- decide whether to enable App Check, then register App Attest/DeviceCheck and
  test it in monitor mode before enforcement;
- verify the production APNs key is uploaded to the production Firebase
  project;
- complete App Store privacy, notification, camera and local-network
  disclosures;
- confirm no customer details, notification bodies, device tokens, or PINs
  appear in application logs.
