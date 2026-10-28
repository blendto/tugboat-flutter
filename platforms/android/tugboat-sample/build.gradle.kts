plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Collector for device tests (native SDK note section 10). Override with
// `-Ptugboat.collectorUrl=… -Ptugboat.collectorKey=…`; the defaults reach a
// local collector on the emulator's host loopback.
val collectorUrl = providers.gradleProperty("tugboat.collectorUrl").orElse("http://10.0.2.2:3000").get()
val collectorKey = providers.gradleProperty("tugboat.collectorKey").orElse("pmk_blend-app-dev-secret").get()
// `TugboatConfig.enabled`. The SDK defaults to dormant; the sample starts a
// session at launch so the device-test script records from the first screen.
// `-Ptugboat.enabled=false` builds a dormant sample for activation scripts.
val tugboatEnabled = providers.gradleProperty("tugboat.enabled").orElse("true").get().toBoolean()

android {
    namespace = "com.tugboat.sample"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.tugboat.sample"
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        buildConfigField("String", "COLLECTOR_URL", "\"$collectorUrl\"")
        buildConfigField("String", "COLLECTOR_KEY", "\"$collectorKey\"")
        buildConfigField("boolean", "TUGBOAT_ENABLED", "$tugboatEnabled")
    }

    buildFeatures {
        buildConfig = true
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlinOptions {
        jvmTarget = "11"
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }
}

dependencies {
    implementation(project(":tugboat-android"))
    implementation(project(":tugboat-compose"))
    // The app's HTTP client, recorded by tugboat-okhttp (which has OkHttp compileOnly).
    implementation(project(":tugboat-okhttp"))
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("androidx.recyclerview:recyclerview:1.3.2")
    // FragmentsActivity: fragments without Jetpack Navigation (route keys from fragment tags).
    implementation("androidx.fragment:fragment:1.7.1")
    // DialogsActivity: an AppCompat AlertDialog (a ComponentDialog) for the dialog-window device pass.
    implementation("androidx.appcompat:appcompat:1.7.0")
    // ViewCompat window insets: edge-to-edge is enforced for targetSdk 35 on API 35+.
    implementation("androidx.core:core:1.13.1")
    // Compose UI 1.8.3: inside tugboat-compose's tested range (1.7.0 to 1.9.0).
    implementation(platform("androidx.compose:compose-bom:2025.06.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.navigation:navigation-compose:2.8.5")

    // Robolectric checks of the sample screens (no keyboard or focus on entry).
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14.1")
    testImplementation("androidx.compose.ui:ui-test-junit4")
}
