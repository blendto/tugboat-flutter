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
        // The Views adapter tests resolve resource entry names (R.id.*).
        unitTests.isIncludeAndroidResources = true
        // Byte-exact fixtures shared with the Apple host (conformance/host),
        // and the identity-parts vectors the Views adapter hashes against.
        val hostFixtures = rootProject.projectDir.resolve("../../conformance/host").canonicalFile
        val identityFixtures = rootProject.projectDir.resolve("../../conformance/fingerprint/identity_parts").canonicalFile
        unitTests.all { test ->
            test.systemProperty("tugboat.hostFixtures", hostFixtures.path)
            test.inputs.dir(hostFixtures)
            test.systemProperty("tugboat.identityFixtures", identityFixtures.path)
            test.inputs.dir(identityFixtures)
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

// The Views adapter supports these androidx libraries when the app has them,
// without depending on them: each is probed on the classpath at runtime.
val optionalAndroidx = listOf(
    "androidx.core:core:1.13.1",
    "androidx.fragment:fragment:1.7.1",
    "androidx.recyclerview:recyclerview:1.3.2",
)

// `Tugboat.trackNavigation(navController)` compiles against Jetpack
// Navigation; only apps that have it can call it.
val optionalNavigation = "androidx.navigation:navigation-runtime:2.7.7"

dependencies {
    // The pixel runtime (window capture, masks before encoding), built from this repository.
    implementation(project(":capture-runtime"))
    // ProcessLifecycleOwner for `app.lifecycle` (native SDK note section 5).
    implementation("androidx.lifecycle:lifecycle-process:2.8.7")
    optionalAndroidx.forEach { compileOnly(it) }
    optionalAndroidx.forEach { testImplementation(it) }
    compileOnly(optionalNavigation)
    testImplementation(optionalNavigation)
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
