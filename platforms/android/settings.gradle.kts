pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("com.android.library") version "8.9.1" apply false
    id("com.android.application") version "8.9.1" apply false
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
    id("com.vanniktech.maven.publish") version "0.34.0" apply false
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri("${rootDir}/../../.local-maven")
        }
    }
}

rootProject.name = "tugboat-android"
include(":capture-runtime")
include(":capture-runtime-test")

val runtimeVersion =
    java.util.Properties()
        .apply { rootDir.resolve("gradle.properties").inputStream().use(::load) }
        .getProperty("VERSION_NAME")
        ?: error("VERSION_NAME is missing from platforms/android/gradle.properties")
val localAar =
    rootDir.resolve(
        "../../.local-maven/com/tugboat/sdk/capture-runtime/$runtimeVersion/capture-runtime-$runtimeVersion.aar",
    )
if (localAar.isFile) {
    include(":sample")
}
