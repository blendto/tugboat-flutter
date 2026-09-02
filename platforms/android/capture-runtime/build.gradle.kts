plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("com.vanniktech.maven.publish")
}

android {
    namespace = "com.tugboat.capture.runtime"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    defaultConfig {
        minSdk = 21
        consumerProguardFiles("consumer-rules.pro")
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }
        externalNativeBuild {
            cmake {
                arguments += listOf(
                    "-DTB_IMAGE_CORE_DIR=${rootProject.projectDir.resolve("../../core/image-processing").canonicalPath}",
                    "-DTB_IMAGE_CORE_BUILD_TESTS=OFF",
                    "-DANDROID_STL=c++_static",
                )
            }
        }
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
}

mavenPublishing {
    coordinates(
        groupId = "com.gettugboat.sdk",
        artifactId = "capture-runtime",
        version = providers.gradleProperty("VERSION_NAME").get(),
    )
    if (providers.gradleProperty("tugboat.publishMavenCentral").orElse("false").get() == "true") {
        publishToMavenCentral(automaticRelease = true)
        signAllPublications()
    }
}

publishing {
    repositories {
        maven {
            name = "LocalCapture"
            url = uri(rootProject.projectDir.resolve("../../.local-maven"))
        }
        val githubUser = providers.gradleProperty("githubPackagesUsername")
        val githubPassword = providers.gradleProperty("githubPackagesPassword")
        if (githubUser.isPresent && githubPassword.isPresent) {
            maven {
                name = "GitHubPackages"
                url = uri("https://maven.pkg.github.com/blendto/tugboat-flutter")
                credentials {
                    username = githubUser.get()
                    password = githubPassword.get()
                }
            }
        }
    }
}
