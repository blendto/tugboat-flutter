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
    .testTarget(
      name: "TugboatCaptureRuntimeTests",
      dependencies: ["TugboatCaptureRuntime"],
      path: "platforms/apple/Tests/TugboatCaptureRuntimeTests"
    ),
  ],
  cxxLanguageStandard: .cxx17
)
