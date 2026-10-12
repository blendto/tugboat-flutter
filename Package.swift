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
    // Native SwiftUI SDK (ADR 0009, native SDK design note section 1):
    // `Tugboat.start`, `.tugboatTag`, `.tugboatScreen`. Unpublished.
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
    // The SwiftUI SDK: Swift host for the session engine (calls its C ABI
    // directly), the SwiftUI adapter, and capture. The pixel runtime is
    // UIKit-only, so it is linked on iOS; the UIKit parts of `Tugboat` are
    // behind `#if canImport(UIKit)` and `swift build` on a Mac still checks
    // the rest.
    .target(
      name: "Tugboat",
      dependencies: [
        "TugboatSessionEngine",
        .target(name: "TugboatCaptureRuntime", condition: .when(platforms: [.iOS])),
      ],
      path: "platforms/apple/Sources/Tugboat",
      exclude: ["README.md", "CHANGELOG.md"]
    ),
    .testTarget(
      name: "TugboatTests",
      dependencies: [
        "Tugboat",
        "TugboatSessionEngine",
        .target(name: "TugboatCaptureRuntime", condition: .when(platforms: [.iOS])),
      ],
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
