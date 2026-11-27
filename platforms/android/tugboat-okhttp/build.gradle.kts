plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("com.vanniktech.maven.publish")
}

// Versioned independently (ADR 0008). Unpublished: the only repository
// below is the untracked `.local-maven`.
val tugboatOkHttpVersion = "0.1.0"

// OkHttp is `compileOnly` (README "OkHttp versions"): the app ships it, and
// this module never changes the app's version. The module compiles against
// the floor, so it calls no newer API. The unit tests run against the
// version below; `-Ptugboat.okhttpTest=3.14.9` runs them on the floor and
// `-Ptugboat.okhttpTest=4.12.0` on the last 4.x.
val okhttpFloor = "3.14.9"
val okhttpTestVersion = providers.gradleProperty("tugboat.okhttpTest").getOrElse("5.3.2")

android {
    namespace = "com.tugboat.android.okhttp"
    compileSdk = 36

    defaultConfig {
        minSdk = 24
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlinOptions {
        jvmTarget = "11"
        // The HTTP-adapter seam of tugboat-android is opt-in, for Tugboat's own adapters.
        freeCompilerArgs += "-opt-in=com.tugboat.android.adapter.TugboatAdapterApi"
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
        unitTests.isIncludeAndroidResources = true
        // The jsonText fixtures, served as HTTP bodies (TugboatOkHttpFixturesTest).
        val evidenceFixtures = rootProject.projectDir.resolve("../../conformance/evidence").canonicalFile
        unitTests.all { test ->
            test.systemProperty("tugboat.evidenceFixtures", evidenceFixtures.path)
            test.systemProperty("tugboat.okhttpTest", okhttpTestVersion)
            test.inputs.dir(evidenceFixtures)
        }
    }
}

dependencies {
    implementation(project(":tugboat-android"))
    compileOnly("com.squareup.okhttp3:okhttp") {
        version { require(okhttpFloor) }
    }

    testImplementation("com.squareup.okhttp3:okhttp:$okhttpTestVersion")
    testImplementation("com.squareup.okhttp3:mockwebserver:$okhttpTestVersion")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14.1")
}

mavenPublishing {
    coordinates(
        groupId = "com.gettugboat.sdk",
        artifactId = "tugboat-okhttp",
        version = tugboatOkHttpVersion,
    )
    pom {
        name.set("Tugboat OkHttp")
        description.set("OkHttp interceptor that records network calls for the Tugboat native Android SDK.")
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
