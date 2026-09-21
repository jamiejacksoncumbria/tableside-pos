# TableSideCY update distribution

TableSideCY uses two update mechanisms because Shorebird does not provide
Flutter Web code push:

| Platform | Baseline distribution | Dart-only updates |
| --- | --- | --- |
| Android | Shorebird release, then APK/AAB distribution | Shorebird patch |
| iOS | Shorebird release, then TestFlight/App Store | Shorebird patch |
| Windows | Shorebird release, then the TableSideCY ZIP/installer | Shorebird patch |
| Web | Firebase Hosting | Rebuild and atomically deploy Firebase Hosting |

The installed-platform app periodically checks for a signed patch without
blocking POS startup, ordering, payment, printing, or offline operation. After
download it displays a persistent restart message. Web builds receive the
latest hosted files; Firebase sends no-cache headers for the app shell and
Flutter service worker so old deployments are not retained unnecessarily.

## One-time Shorebird account setup

Do this before uploading the first TestFlight build. A build made with stock
`flutter build` cannot receive a Shorebird patch later.

### macOS

```bash
curl --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/shorebirdtech/install/main/install.sh \
  -sSf | bash
source ~/.zshrc
shorebird login
shorebird doctor

cd ~/StudioProjects/tableside-pos
shorebird init
git add shorebird.yaml
git commit -m "build: initialize Shorebird updates"
git push
```

`shorebird init` creates the real application ID in `shorebird.yaml`. Never
invent or copy an ID from a different application.

### Create the patch-signing key once

Do this before the first release so every installed app rejects unsigned or
tampered patches:

```bash
mkdir -p ~/.tablesidecy/shorebird
openssl genrsa -out ~/.tablesidecy/shorebird/private.pem 2048
openssl rsa -in ~/.tablesidecy/shorebird/private.pem \
  -outform PEM -pubout -out ~/.tablesidecy/shorebird/public.pem
chmod 600 ~/.tablesidecy/shorebird/private.pem

export SHOREBIRD_PRIVATE_KEY_PATH="$HOME/.tablesidecy/shorebird/private.pem"
export SHOREBIRD_PUBLIC_KEY_PATH="$HOME/.tablesidecy/shorebird/public.pem"
```

Keep an encrypted backup of the private key outside the computer. Never commit
it, email it, or paste it into support messages. Losing it means existing
releases cannot receive another valid patch and must be replaced by a new store
release. For production automation, migrate the key into a cloud KMS or secrets
manager rather than keeping it as a normal file.

### Windows

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
iwr -UseBasicParsing 'https://raw.githubusercontent.com/shorebirdtech/install/main/install.ps1' | iex
shorebird login
shorebird doctor
```

The committed `shorebird.yaml` is shared by Windows and macOS checkouts.
Set `SHOREBIRD_PUBLIC_KEY_PATH` and `SHOREBIRD_PRIVATE_KEY_PATH` in the Windows
user environment to the same securely transferred key pair before using the
release menu.

## First iOS/TestFlight baseline

The first archive submitted to TestFlight must be the Shorebird baseline:

```bash
cd ~/StudioProjects/tableside-pos
chmod +x tableside-release.sh
./tableside-release.sh release-ios staging
```

Upload the generated IPA/archive to App Store Connect. Shorebird patches are
not supported in the iOS simulator; validate them using the TestFlight build on
a physical iPhone or iPad.

## Patch workflow

A patch may change Dart code and compatible Dart-only dependencies. Changes to
Swift, Objective-C, Kotlin, Java, C++, entitlements, permissions, native
plugins, or bundled assets require a new release and store/installer update.

Create patches on a test track first and validate ordering, payment, printing,
offline hub operation and startup before promoting to stable.

Staging builds subscribe to the Shorebird `staging` track. Production builds
subscribe only to `stable`, preventing an unapproved staging patch from reaching
live restaurants.

```bash
# macOS / iOS
./tableside-release.sh patch-ios staging

# Windows menu
.\tableside-build.ps1 -Action ShorebirdPatchWindows -Environment Staging

# Android menu
.\tableside-build.ps1 -Action ShorebirdPatchAndroid -Environment Staging
```

For new baseline releases use `ShorebirdReleaseWindows`,
`ShorebirdReleaseAndroid`, or `release-ios`. Every store submission must have a
new build number.

## Web deployment

Web updates do not use Shorebird. Build and deploy them atomically through the
existing Firebase Hosting action:

```powershell
.\tableside-build.ps1 -Action DeployWeb -Environment Staging
```

Do not present a successful web build as deployed until the Firebase deploy
command itself reports success.

## Operational safeguards

- Keep the previous stable patch/release available for rollback.
- Never patch a different Firebase environment into an existing release.
- Do not force-restart a device while it has unsent orders or print jobs.
- The app continues normally if Shorebird is unreachable.
- Offline devices retain their installed release/patch and update only after
  connectivity returns.
- TestFlight and App Store policy compliance remains required for every patch.
