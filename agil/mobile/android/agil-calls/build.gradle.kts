import org.gradle.api.publish.maven.MavenPublication

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    `maven-publish`
}

android {
    namespace = "com.agilcalls.sdk"
    compileSdk = 35

    defaultConfig {
        minSdk = 26
        consumerProguardFiles("consumer-rules.pro")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
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
    // Deliberately dependency-free: platform WebView/HttpURLConnection/org.json.
    testImplementation("junit:junit:4.13.2")
    // Real org.json for pure-JVM tests (the android.jar stub throws on use).
    testImplementation("org.json:json:20180813")
}

afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                groupId = "com.agilcalls"
                artifactId = "agil-calls"
                version = "0.1.0"
                pom {
                    name.set("AgilFrame Android SDK")
                    description.set(
                        "Tier-1 Android WebView SDK for the hosted AgilFrame widget: " +
                            "call view, events, commands and a join API.",
                    )
                    url.set("https://github.com/agil/video-calls")
                    licenses {
                        license {
                            name.set("Proprietary")
                            comments.set("AgilFrame is proprietary software of its owner.")
                        }
                    }
                    scm {
                        url.set("https://github.com/agil/video-calls")
                        connection.set("scm:git:https://github.com/agil/video-calls.git")
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
