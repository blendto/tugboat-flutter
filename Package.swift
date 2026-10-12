// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "TugboatCaptureRuntime",
  platforms: [
    .iOS(.v15),
  ],
  products: [
    .library(
      name: "TugboatCaptureRuntime",
      targets: ["TugboatCaptureRuntime"]
    ),
    // Native SDK (ADR 0009, native SDK design note section 1). Platform
    // plumbing only for now: every type in the module is internal.
    .library(
      name: "Tugboat",
      targets: ["Tugboat"]
    ),
  ],
  targets: [
    .target(
      name: "TugboatImageCore",
      path: "core/image-processing",
      exclude: [
        "CMakeLists.txt",
        "README.md",
        "tests",
        "fuzz",
      ],
      sources: ["src/tb_image_core.cpp"],
      publicHeadersPath: "include",
      cxxSettings: [
        .headerSearchPath("include"),
      ],
      linkerSettings: [
        .linkedLibrary("c++"),
      ]
    ),
    .target(
      name: "TugboatImageCoreBridge",
      dependencies: ["TugboatImageCore"],
      path: "platforms/apple/Sources/TugboatImageCoreBridge",
      publicHeadersPath: ".",
      cxxSettings: [
        .headerSearchPath("../../../../core/image-processing/include"),
      ],
      linkerSettings: [
        .linkedLibrary("c++"),
      ]
    ),
    .target(
      name: "TugboatCaptureRuntime",
      dependencies: ["TugboatImageCoreBridge"],
      path: "platforms/apple/Sources/TugboatCaptureRuntime"
    ),
    // ADR 0009 session engine. Internal for now: the native SDK product
    // (`Tugboat`) will depend on it; adapters never compile it themselves.
    .target(
      name: "TugboatSessionEngine",
      path: "core/session-engine",
      exclude: [
        "CMakeLists.txt",
        "README.md",
        "docs",
        "tests",
        "fuzz",
        "third_party/double-conversion/AUTHORS",
        "third_party/double-conversion/LICENSE",
      ],
      sources: [
        "src",
        "third_party/double-conversion/double-conversion",
      ],
      publicHeadersPath: "include",
      cxxSettings: [
        .headerSearchPath("src"),
        .headerSearchPath("third_party/double-conversion"),
      ],
      linkerSettings: [
        .linkedLibrary("c++"),
      ]
    ),
    // Swift host for the session engine. Calls the engine's C ABI directly.
    .target(
      name: "Tugboat",
      dependencies: ["TugboatSessionEngine"],
      path: "platforms/apple/Sources/Tugboat",
      exclude: ["README.md", "CHANGELOG.md"]
    ),
    .testTarget(
      name: "TugboatTests",
      dependencies: ["Tugboat", "TugboatSessionEngine"],
      path: "platforms/apple/Tests/TugboatTests"
    ),
    .testTarget(
      name: "TugboatSessionEngineTests",
      dependencies: ["TugboatSessionEngine"],
      path: "platforms/apple/Tests/TugboatSessionEngineTests"
    ),
    .testTarget(
      name: "TugboatCaptureRuntimeTests",
      dependencies: ["TugboatCaptureRuntime"],
      path: "platforms/apple/Tests/TugboatCaptureRuntimeTests"
    ),
  ],
  cxxLanguageStandard: .cxx17
)
