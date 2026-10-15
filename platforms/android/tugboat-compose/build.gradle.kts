plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.vanniktech.maven.publish")
}

// Versioned independently (ADR 0008). Unpublished: the only repository
// below is the untracked `.local-maven`.
val tugboatComposeVersion = "0.2.0"

// Compose UI support (README "Compose versions"). Compose UI is
// `compileOnly`: a Compose app already ships it, and an app below the
// tested floor is not force-upgraded; it fails the runtime version gate
// (`ComposeUiVersion`) and its hosts are masked whole. The module compiles
// against the floor, so it calls no newer API. The unit tests run against
// the BOM below; `-Ptugboat.composeBom=2024.09.00` runs them on the floor.
val composeUiFloor = "1.7.0"
val composeTestBom = providers.gradleProperty("tugboat.composeBom").getOrElse("2025.06.01") // Compose UI 1.8.3

android {
    namespace = "com.tugboat.android.compose"
    compileSdk = 36

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
    }

    buildFeatures {
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlinOptions {
        jvmTarget = "11"
        // The toolkit-region seam of tugboat-android is opt-in, for Tugboat's own toolkit modules.
        freeCompilerArgs += "-opt-in=com.tugboat.android.toolkit.TugboatToolkitApi"
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
        unitTests.isIncludeAndroidResources = true
    }
}

dependencies {
    implementation(project(":tugboat-android"))
    compileOnly("androidx.compose.ui:ui") {
        version { require(composeUiFloor) }
    }

    // Region-level tests only; the end-to-end tests through the Views
    // adapter live in tugboat-android (`src/test/.../compose`).
    testImplementation(platform("androidx.compose:compose-bom:$composeTestBom"))
    testImplementation("androidx.compose.ui:ui")
    testImplementation("androidx.compose.foundation:foundation")
    testImplementation("androidx.compose.material3:material3")
    testImplementation("androidx.compose.ui:ui-test-junit4")
    testImplementation("androidx.compose.ui:ui-test-manifest")
    testImplementation("androidx.activity:activity-compose:1.9.3")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14.1")
}

mavenPublishing {
    coordinates(
        groupId = "com.gettugboat.sdk",
        artifactId = "tugboat-compose",
        version = tugboatComposeVersion,
    )
    pom {
        name.set("Tugboat Compose")
        description.set("Jetpack Compose adapter for the Tugboat native Android SDK.")
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
