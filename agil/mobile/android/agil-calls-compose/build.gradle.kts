import org.gradle.api.publish.maven.MavenPublication

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    `maven-publish`
}

android {
    namespace = "com.agilcalls.compose"
    compileSdk = 35

    defaultConfig {
        minSdk = 26
        consumerProguardFiles("consumer-rules.pro")
    }

    buildFeatures {
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    // The Compose wrapper is an optional module so the core stays dependency-free.
    api(project(":agil-calls"))
    api(platform("androidx.compose:compose-bom:2024.12.01"))
    api("androidx.compose.ui:ui")
    implementation("androidx.compose.runtime:runtime")
}

afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                groupId = "com.agilcalls"
                artifactId = "agil-calls-compose"
                version = "0.1.0"
                pom {
                    name.set("AgilFrame Android SDK - Compose wrapper")
                    description.set("Jetpack Compose AgilCall wrapper around the AgilFrame Android WebView SDK.")
                    url.set("https://github.com/agil/video-calls")
                    licenses {
                        license {
                            name.set("Proprietary")
                            comments.set("AgilFrame is proprietary software of its owner.")
                        }
                    }
                    developers {
                        developer {
                            id.set("agil-calls")
                            name.set("AgilFrame")
                        }
                    }
                }
            }
        }
    }
}
