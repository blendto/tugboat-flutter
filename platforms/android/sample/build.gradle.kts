plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.tugboat.capture.sample"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.tugboat.capture.sample"
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = providers.gradleProperty("VERSION_NAME").get()
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
    implementation("com.tugboat.sdk:capture-runtime:${providers.gradleProperty("VERSION_NAME").get()}")
}
