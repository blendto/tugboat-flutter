// swift-tools-version: 5.9
import PackageDescription

// `TugboatAlamofire`: an optional Alamofire `EventMonitor` that records each
// logical request as Tugboat `network_call` evidence. Its own package, so
// the root package (`Tugboat`) never makes its consumers fetch Alamofire.
// SwiftPM only (no podspec: there is no `Tugboat` podspec yet). Unpublished.
let package = Package(
  name: "TugboatAlamofire",
  platforms: [
    .iOS(.v15),
    .macOS(.v12),
  ],
  products: [
    .library(name: "TugboatAlamofire", targets: ["TugboatAlamofire"]),
  ],
  dependencies: [
    // The repository root package, which vends `Tugboat`.
    .package(name: "TugboatCaptureRuntime", path: "../../.."),
    // 5.9.0 ships Alamofire's privacy manifest (PrivacyInfo.xcprivacy); the
    // EventMonitor events used here exist since 5.0.
    .package(url: "https://github.com/Alamofire/Alamofire.git", .upToNextMajor(from: "5.9.0")),
  ],
  targets: [
    .target(
      name: "TugboatAlamofire",
      dependencies: [
        .product(name: "Tugboat", package: "TugboatCaptureRuntime"),
        .product(name: "Alamofire", package: "Alamofire"),
      ]
    ),
    .testTarget(
      name: "TugboatAlamofireTests",
      dependencies: [
        "TugboatAlamofire",
        .product(name: "Tugboat", package: "TugboatCaptureRuntime"),
        .product(name: "Alamofire", package: "Alamofire"),
      ]
    ),
  ]
)
