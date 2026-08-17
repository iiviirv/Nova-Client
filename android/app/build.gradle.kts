import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: load the keystore details from android/key.properties (which
// is gitignored and never committed). When the file is absent (e.g. a plain CI
// analysis run, or a contributor without the key), we fall back to debug signing
// so the build still succeeds, it just isn't the distributable, updatable APK.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "online.novaproxy.nova_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "online.novaproxy.nova_client"
        // libbox.aar (main variant) is built with androidapi 23, so minSdk >= 23.
        minSdk = 24
        // Google Play requires targetSdk 35 (Android 15) for new releases. The
        // VpnService runs as a "systemExempted" foreground service, which on
        // Android 14+ needs the FOREGROUND_SERVICE_SYSTEM_EXEMPTED permission
        // (declared in the manifest), matching the sing-box-for-android core.
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // The gomobile-built libbox.aar ships native .so files that must be
    // extracted (legacy packaging) to load reliably.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Use the permanent Nova release key when key.properties is present
            // (the distributable, updatable APK). Without it, fall back to the
            // debug key so analysis/CI-without-secrets still builds.
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Keep rules for ML Kit / mobile_scanner: R8 was stripping ML Kit
            // internals the plugin's own consumer rules miss, crashing the QR
            // scanner on release builds before the camera opened.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

dependencies {
    // The sing-box core. Built by CI (build-apk workflow) and copied into
    // app/libs/ before assembling the APK; absent during plain analysis.
    val libbox = file("libs/libbox.aar")
    if (libbox.exists()) {
        implementation(files(libbox))
    }

    // The Xray core (Phase-2 xhttp spike), built by tool/core/build-xray.sh.
    // Optional: only present when the xhttp feature is being built/tested.
    val libxray = file("libs/libxray.aar")
    if (libxray.exists()) {
        implementation(files(libxray))
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
