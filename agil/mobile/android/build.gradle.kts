// Root build file. Versions are pinned to the documented toolchain:
// JDK 17, Gradle 8.9+, AGP 8.7.3, Kotlin 2.1.0.
plugins {
    id("com.android.library") version "8.7.3" apply false
    id("com.android.application") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.1.0" apply false
}

allprojects {
    group = "com.agilcalls"
    version = "0.1.0"
}
