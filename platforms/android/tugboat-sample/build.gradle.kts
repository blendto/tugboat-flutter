plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Collector for device tests (native SDK note section 10). Override with
// `-Ptugboat.collectorUrl=… -Ptugboat.collectorKey=…`; the defaults reach a
// local collector on the emulator's host loopback.
val collectorUrl = providers.gradleProperty("tugboat.collectorUrl").orElse("http://10.0.2.2:3000").get()
val collectorKey = providers.gradleProperty("tugboat.collectorKey").orElse("pmk_blend-app-dev-secret").get()

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
}

dependencies {
    implementation(project(":tugboat-android"))
    implementation("androidx.recyclerview:recyclerview:1.3.2")
}
