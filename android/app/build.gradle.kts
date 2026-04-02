plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

fun readRootDotEnv(rootDir: java.io.File): Map<String, String> {
    val envFile = rootDir.resolve(".env")
    if (!envFile.exists()) return emptyMap()
    return envFile.readLines().mapNotNull { line ->
        val trimmed = line.trim()
        when {
            trimmed.isEmpty() || trimmed.startsWith("#") -> null
            else -> {
                val idx = trimmed.indexOf('=')
                if (idx <= 0) null
                else {
                    val key = trimmed.substring(0, idx).trim()
                    var value = trimmed.substring(idx + 1).trim()
                    if ((value.startsWith("\"") && value.endsWith("\"")) ||
                        (value.startsWith("'") && value.endsWith("'"))
                    ) {
                        value = value.substring(1, value.length - 1)
                    }
                    key to value
                }
            }
        }
    }.toMap()
}

android {
    namespace = "com.example.trucker_assistant_flutter"
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
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.trucker_assistant_flutter"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        val env = readRootDotEnv(rootProject.projectDir.parentFile)
        manifestPlaceholders["GOOGLE_MAPS_API_KEY"] = env["GOOGLE_MAPS_API_KEY"] ?: ""
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
