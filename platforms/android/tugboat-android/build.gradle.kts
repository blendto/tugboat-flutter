plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("com.vanniktech.maven.publish")
}

// Versioned independently of capture-runtime (ADR 0008). Unpublished: the
// only repository below is the untracked `.local-maven`.
val tugboatAndroidVersion = "0.1.0"

android {
    namespace = "com.tugboat.android"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("String", "SDK_VERSION", "\"$tugboatAndroidVersion\"")
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }
        externalNativeBuild {
            cmake {
                arguments += listOf(
                    "-DTB_SESSION_ENGINE_DIR=${rootProject.projectDir.resolve("../../core/session-engine").canonicalPath}",
                    "-DTB_SESSION_ENGINE_BUILD_TESTS=OFF",
                    "-DANDROID_STL=c++_static",
                )
            }
        }
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlinOptions {
        jvmTarget = "11"
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
        // Byte-exact fixtures shared with the Apple host (conformance/host).
        val hostFixtures = rootProject.projectDir.resolve("../../conformance/host").canonicalFile
        unitTests.all { test ->
            test.systemProperty("tugboat.hostFixtures", hostFixtures.path)
            test.inputs.dir(hostFixtures)
        }
    }

    buildTypes {
        release {
            ndk {
                debugSymbolLevel = "SYMBOL_TABLE"
            }
        }
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
}

mavenPublishing {
    coordinates(
        groupId = "com.gettugboat.sdk",
        artifactId = "tugboat-android",
        version = tugboatAndroidVersion,
    )
    pom {
        name.set("Tugboat Android")
        description.set("Native Android host for the Tugboat session engine.")
    }
}

publishing {
    repositories {
        maven {
            name = "LocalCapture"
            url = uri(rootProject.projectDir.resolve("../../.local-maven"))
        }
    }
}
