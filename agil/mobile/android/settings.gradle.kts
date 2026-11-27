// Standalone Gradle build for the AgilFrame Android SDK.
//
// The repository intentionally does not ship a Gradle wrapper for this module:
// use a local Gradle 8.9+ installation (see docs/android-sdk.md).
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "agil-calls-android"

include(":agil-calls")
include(":agil-calls-compose")
include(":example")
