import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release artifacts must never fall back to Flutter's public debug key. The
// local key.properties file is ignored by Git; CI can provide the passwords as
// environment variables so that no signing secret is stored in this checkout.
val releaseKeyPropertiesFile = rootProject.file("key.properties")
val releaseKeyProperties = Properties()
if (releaseKeyPropertiesFile.exists()) {
    releaseKeyPropertiesFile.inputStream().use(releaseKeyProperties::load)
}

fun releaseSigningValue(propertyName: String, environmentName: String): String? =
    System.getenv(environmentName)?.trim()?.takeIf(String::isNotEmpty)
        ?: releaseKeyProperties.getProperty(propertyName)?.trim()?.takeIf(String::isNotEmpty)

val releaseStoreFile = releaseSigningValue(
    "storeFile",
    "TABLESIDECY_ANDROID_KEYSTORE_PATH",
)
val releaseStorePassword = releaseSigningValue(
    "storePassword",
    "TABLESIDECY_ANDROID_STORE_PASSWORD",
)
val releaseKeyAlias = releaseSigningValue(
    "keyAlias",
    "TABLESIDECY_ANDROID_KEY_ALIAS",
)
val releaseKeyPassword = releaseSigningValue(
    "keyPassword",
    "TABLESIDECY_ANDROID_KEY_PASSWORD",
)
val requestedReleaseBuild = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}
val missingReleaseSigningValues = buildList {
    if (releaseStoreFile == null) add("storeFile/TABLESIDECY_ANDROID_KEYSTORE_PATH")
    if (releaseStorePassword == null) add("storePassword/TABLESIDECY_ANDROID_STORE_PASSWORD")
    if (releaseKeyAlias == null) add("keyAlias/TABLESIDECY_ANDROID_KEY_ALIAS")
    if (releaseKeyPassword == null) add("keyPassword/TABLESIDECY_ANDROID_KEY_PASSWORD")
}

if (requestedReleaseBuild && missingReleaseSigningValues.isNotEmpty()) {
    throw GradleException(
        "Android release signing is not configured. Missing: " +
            missingReleaseSigningValues.joinToString() +
            ". See docs/android-release-signing.md.",
    )
}

if (requestedReleaseBuild && releaseStoreFile != null &&
    !rootProject.file(releaseStoreFile).isFile
) {
    throw GradleException(
        "The configured Android release keystore does not exist: $releaseStoreFile",
    )
}

android {
    namespace = "uk.co.gopcpitstop.tablesideCY"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "uk.co.gopcpitstop.tablesideCY"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (missingReleaseSigningValues.isEmpty()) {
            create("release") {
                storeFile = rootProject.file(requireNotNull(releaseStoreFile))
                storePassword = requireNotNull(releaseStorePassword)
                keyAlias = requireNotNull(releaseKeyAlias)
                keyPassword = requireNotNull(releaseKeyPassword)
            }
        }
    }

    buildTypes {
        release {
            // A release task is rejected above unless this private signing
            // configuration is complete. Debug signing is never a fallback.
            signingConfig = signingConfigs.findByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
