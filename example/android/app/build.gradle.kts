import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Push notifications use Firebase, configured by google-services.json from
// your own Firebase project (it is git-ignored). Without the file the app
// still builds and rings for calls while it is open.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

// Release signing: android/key.properties (git-ignored, never committed) names
// the upload keystore with storeFile (relative to android/app), storePassword,
// keyAlias and keyPassword. Without it a release build is signed with the
// debug key, so `flutter run --release` still works on a developer's machine;
// Play Console refuses such a build.
val keyProperties = Properties()
val keyPropertiesFile = rootProject.file("key.properties")
if (keyPropertiesFile.exists()) {
    keyPropertiesFile.inputStream().use { keyProperties.load(it) }
} else {
    gradle.taskGraph.whenReady {
        if (allTasks.any { it.name.contains("Release") }) {
            logger.warn(
                "WARNING: android/key.properties not found, so this release build is signed with the " +
                    "DEBUG key. Play Console refuses it. See example/README.md, \"Release builds\".",
            )
        }
    }
}

android {
    namespace = "ai.vobiz.vobiz_webrtc_example"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // The Firebase app (google-services.json) and the push credential in the
        // Vobiz Console are registered for this id, and the app sends it, read at
        // run time, when it signs up for Vobiz push. Changing it needs both anew.
        applicationId = "ai.vobiz.vobiz_webrtc_example"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keyPropertiesFile.exists()) {
            create("release") {
                storeFile = keyProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (keyPropertiesFile.exists()) "release" else "debug")
        }
    }
}

flutter {
    source = "../.."
}
