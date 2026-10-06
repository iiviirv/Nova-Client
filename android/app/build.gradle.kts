import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: load the keystore details from android/key.properties (which
// is gitignored and never committed). CI writes that file from GitHub secrets;
// see the "Set up release signing" step in build-apk.yml.
//
// When the file is absent the build can still fall back to the debug key, but
// only if that is asked for explicitly with -PnovaAllowDebugSigning=true. It
// used to be the silent default, and silence was the problem.
//
// A debug-signed APK is named app-release.apk, is the same size, and installs
// fine on a clean device, so it looks shippable. It is not. Its signature does
// not match the published one, so it cannot update anyone who already has Nova,
// it fails with a signature-mismatch error instead. And it is signed with the
// Android debug key, which every machine on earth has a copy of, so anyone can
// forge an update for it.
//
// This came from a real near miss on 2026-10-06: a stale key.properties on the
// release machine still pointed at the retired CN=Nova Proxy keystore, so local
// builds were signed with a key that could not update anything, and they were
// handed over as release artifacts. Removing the stale file alone would have
// turned a wrong-key build into a debug-signed one, which is worse. Hence the
// gate below.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
val allowDebugSigning = (project.findProperty("novaAllowDebugSigning") as String?) == "true"

// Checked when the task graph is known rather than while configuring, so that
// debug builds, `flutter run`, and every other Gradle task keep working on a
// machine with no key. Only an actual release assembly is refused.
gradle.taskGraph.whenReady {
    if (hasReleaseKeystore || allowDebugSigning) return@whenReady
    val releaseTask = allTasks.firstOrNull {
        it.project.path == project.path &&
            it.name.startsWith("assemble") &&
            it.name.contains("Release")
    }
    if (releaseTask != null) {
        throw GradleException(
            "Refusing to build a release APK with no signing key.\n" +
                "  android/key.properties is absent, so this would be signed with the " +
                "Android DEBUG key.\n" +
                "  That APK cannot update an existing install and is not distributable, " +
                "but it is named app-release.apk and looks exactly like one.\n" +
                "  The real key lives in GitHub secrets and CI signs the published " +
                "builds; build releases there.\n" +
                "  If you genuinely want a throwaway debug-signed build, pass " +
                "-PnovaAllowDebugSigning=true.",
        )
    }
}

android {
    namespace = "online.novaproxy.nova_client"
    compileSdk = 36  // file_picker's lifecycle dep needs 36; targetSdk stays 35
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
                // Sign with v2 AND v3. Shipped APKs were v2-only, which is the
                // bare minimum for minSdk 24 but leaves out the scheme every
                // Android 9+ device prefers and the one that carries key-rotation
                // proof. This is signing hygiene, not a fix for the Play Protect
                // "unknown developer" warning (that is reputation on the signing
                // key, see docs/play-protect-warning.md).
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        release {
            // Use the permanent Nova release key when key.properties is present
            // (the distributable, updatable APK). Without it this is the debug
            // key, which the task-graph check above refuses unless it was asked
            // for with -PnovaAllowDebugSigning=true.
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

    // NotificationCompat for the ongoing VPN status notification. Also arrives
    // transitively via the Flutter embedding; pinned here so the service's
    // notification code never depends on that resolution.
    implementation("androidx.core:core-ktx:1.13.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
