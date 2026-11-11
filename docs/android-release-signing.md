# Android release signing

TableSideCY release APKs, App Bundles, and Shorebird baselines must be signed
with the private upload key. The Gradle build deliberately fails rather than
falling back to Flutter's public debug key.

## One-time setup on Windows

From the repository root, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\create-android-upload-keystore.ps1
```

`keytool` asks for a strong password and certificate details. The helper writes:

- the private key to `%USERPROFILE%\.tablesidecy\android-upload-keystore.jks`;
- the ignored local configuration to `android\key.properties`.

The helper refuses to overwrite either file. Keep the only operational copy of
the key outside the repository.

Before each release build, set the secrets in that PowerShell session:

```powershell
$env:TABLESIDECY_ANDROID_STORE_PASSWORD = '<from password manager>'
$env:TABLESIDECY_ANDROID_KEY_PASSWORD = '<from password manager>'
.\tableside-build.ps1 -Action BuildAppBundle -Environment Production
```

For Shorebird, use the same environment variables with
`ShorebirdReleaseAndroid` or `ShorebirdPatchAndroid`. This ensures store updates
and Shorebird baselines retain the same Android application identity.

CI can configure all four values without creating `key.properties`:

- `TABLESIDECY_ANDROID_KEYSTORE_PATH`
- `TABLESIDECY_ANDROID_STORE_PASSWORD`
- `TABLESIDECY_ANDROID_KEY_ALIAS`
- `TABLESIDECY_ANDROID_KEY_PASSWORD`

## Required backups

Before uploading the first production App Bundle:

1. Keep two encrypted backups of the keystore in separate locations.
2. Store the passwords and alias in a password manager, separately from the key.
3. Record which Google Play application and Shorebird app use the key.
4. Register the signing certificate SHA-256 fingerprint with Firebase and App
   Check.
5. Never email, commit, or place the keystore in a shared project folder.

Losing the upload key can block direct APK upgrades and complicate store
releases. A staging key and production key should be different.

## Verification

Build the production App Bundle, then verify its certificate:

```powershell
keytool -printcert -jarfile .\build\app\outputs\bundle\release\app-release.aab
```

The owner and SHA-256 fingerprint must match the secured production upload key;
they must not identify `Android Debug`.
