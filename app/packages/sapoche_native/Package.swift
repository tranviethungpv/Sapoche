// swift-tools-version: 5.9
// Development only: builds and tests the portable part of the iOS native side (ios/sapoche_native/Sources/sapoche_native/Core)
// on Linux, where there is no Xcode. The app itself builds from ios/sapoche_native/Package.swift.
import PackageDescription

let package = Package(
  name: "SapocheCore",
  products: [.library(name: "SapocheCore", targets: ["SapocheCore"])],
  dependencies: [
    // CryptoKit is Apple's; on Linux the same calls come from swift-crypto. The app itself (CocoaPods) uses CryptoKit only.
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
  ],
  targets: [
    .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
    .target(
      name: "SapocheCore",
      dependencies: [
        "CSQLite",
        .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
      ],
      path: "ios/sapoche_native/Sources/sapoche_native/Core"
    ),
    .testTarget(
      name: "SapocheCoreTests",
      dependencies: ["SapocheCore"],
      path: "Tests/SapocheCoreTests",
      resources: [.copy("Fixtures")]
    ),
  ],
)
