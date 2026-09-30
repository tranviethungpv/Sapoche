import java.net.URI
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Room server and shared secret come from unison.properties, which is not committed. Not
// local.properties: the Flutter tool rewrites that file on every build and drops unknown keys.
val localProperties = Properties().apply {
    rootProject.file("unison.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}

val serverUrl = localProperties.getProperty("unison.serverUrl", "https://your-worker.example.workers.dev")

android {
    namespace = "app.unison"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // NewPipeExtractor uses java.time and other APIs missing on older Android
        isCoreLibraryDesugaringEnabled = true
    }

    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.unison"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        buildConfigField("String", "SERVER_URL", "\"$serverUrl\"")
        // Invitation links (https://<server>/join/CODE) open the app directly once Android has verified the server
        manifestPlaceholders["serverHost"] = URI(serverUrl).host
        buildConfigField("String", "ROOM_KEY", "\"${localProperties.getProperty("unison.roomKey", "")}\"")
    }

    // The release key lives next to unison.properties and is not committed. Without it the release
    // build falls back to the debug key, which still installs but cannot update an app signed for real.
    val releaseKey = localProperties.getProperty("unison.keystore")?.let { rootProject.file(it) }?.takeIf { it.exists() }
    signingConfigs {
        if (releaseKey != null) {
            create("release") {
                storeFile = releaseKey
                storePassword = localProperties.getProperty("unison.keystorePassword")
                keyAlias = localProperties.getProperty("unison.keyAlias")
                keyPassword = localProperties.getProperty("unison.keystorePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
            // Not shrunk: NewPipeExtractor reaches parts of itself by name, and a rule missed by R8 would
            // only show up as a broken search on a phone. The size difference is about ten megabytes.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation(project(":core"))
    implementation(project(":sync"))
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs_nio:2.1.5")

    implementation("androidx.media3:media3-exoplayer:1.11.1")
    implementation("androidx.media3:media3-session:1.11.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")

    // Database tests need the phone's own SQLite; they run with `./gradlew connectedDebugAndroidTest`
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
}

flutter {
    source = "../.."
}
