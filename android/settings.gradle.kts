pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
    // Auto-provision missing JDK toolchains (e.g. biometric_storage pins
    // Java 17, which Android Studio's bundled JBR 21 doesn't satisfy). Lets
    // Gradle download a matching Temurin JDK on demand instead of requiring a
    // JDK 17 to be installed and registered by hand.
    id("org.gradle.toolchains.foojay-resolver-convention") version "0.9.0"
}

include(":app")
