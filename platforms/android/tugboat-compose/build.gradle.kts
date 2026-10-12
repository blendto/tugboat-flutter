import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.vanniktech.maven.publish")
}

// Versioned independently (ADR 0008). Unpublished: the only repository
// below is the untracked `.local-maven`.
val tugboatComposeVersion = "0.1.0"

// Compose UI support (README "Compose versions"): the module compiles
// against the floor of the tested range, so it never calls newer API, and
// the unit tests run against the BOM below. `-Ptugboat.composeBom=...`
// re-runs them against another tested release.
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
        val identityFixtures = rootProject.projectDir.resolve("../../conformance/fingerprint/identity_parts").canonicalFile
        unitTests.all { test ->
            test.systemProperty("tugboat.identityFixtures", identityFixtures.path)
            test.inputs.dir(identityFixtures)
        }
    }
}

dependencies {
    implementation(project(":tugboat-android"))
    implementation("androidx.compose.ui:ui") {
        version { require(composeUiFloor) }
    }

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

// The unit tests drive tugboat-android's internal Views adapter (anchors,
// masks, facts) end to end, so they are compiled as a friend of its debug
// classes of the same variant. Test-only: the module's own code uses the
// public seam alone.
tasks.withType<KotlinCompile>().configureEach {
    val variant = Regex("compile(\\w+)UnitTestKotlin").matchEntire(name)?.groupValues?.get(1) ?: return@configureEach
    friendPaths.from(
        project(":tugboat-android").layout.buildDirectory.file(
            "intermediates/compile_library_classes_jar/${variant.lowercase()}/bundleLibCompileToJar$variant/classes.jar",
        ),
    )
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
