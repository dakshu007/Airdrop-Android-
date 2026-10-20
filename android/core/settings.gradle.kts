// Standalone build so the protocol core can be built and tested on any JVM
// (`gradle -p android/core test`). The Android app includes it as a composite build.
pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
    }
}

rootProject.name = "core"
