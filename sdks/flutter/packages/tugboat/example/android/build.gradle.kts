// Monorepo checkout: the example always runs on the capture-runtime built
// from this repo (platforms/android), whatever version the plugin pins from
// Maven Central. The plugin's pin names what ships and is left as it is.
// Publish the in-repo runtime to .local-maven first:
//   bash tool/ci/publish-android-runtime-local.sh
// TUGBOAT_PUBLISHED_CAPTURE_RUNTIME=1 resolves the plugin's pin instead; only
// tool/ci/verify-flutter-plugin-runtime.sh uses it, to keep that pin honest.
val repoRoot: File = rootDir.resolve("../../../../../..").canonicalFile
val localMaven: File = repoRoot.resolve(".local-maven")
val inRepoRuntimeVersion: String =
    java.util.Properties()
        .apply { repoRoot.resolve("platforms/android/gradle.properties").inputStream().use(::load) }
        .getProperty("VERSION_NAME")
        ?: error("VERSION_NAME is missing from platforms/android/gradle.properties")
val useInRepoRuntime = System.getenv("TUGBOAT_PUBLISHED_CAPTURE_RUNTIME") != "1"

if (useInRepoRuntime) {
    val aar =
        localMaven.resolve(
            "com/gettugboat/sdk/capture-runtime/$inRepoRuntimeVersion/capture-runtime-$inRepoRuntimeVersion.aar",
        )
    check(aar.isFile) {
        "capture-runtime $inRepoRuntimeVersion from this repo is not in .local-maven. " +
            "Build it first: bash tool/ci/publish-android-runtime-local.sh"
    }
}

allprojects {
    repositories {
        if (useInRepoRuntime) {
            exclusiveContent {
                forRepository { maven { url = uri(localMaven) } }
                filter { includeModule("com.gettugboat.sdk", "capture-runtime") }
            }
        }
        google()
        mavenCentral()
    }
    if (useInRepoRuntime) {
        configurations.configureEach {
            resolutionStrategy.eachDependency {
                if (requested.group == "com.gettugboat.sdk" && requested.name == "capture-runtime") {
                    useVersion(inRepoRuntimeVersion)
                    because("the example builds against the in-repo capture-runtime")
                }
            }
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
