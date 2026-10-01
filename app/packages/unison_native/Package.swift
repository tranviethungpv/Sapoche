// swift-tools-version: 5.9
// Development only: builds and tests the portable part of the iOS native side (ios/unison_native/Sources/unison_native/Core)
// on Linux, where there is no Xcode. The app itself builds from ios/unison_native/Package.swift.
import PackageDescription

let package = Package(
  name: "UnisonCore",
  products: [.library(name: "UnisonCore", targets: ["UnisonCore"])],
  targets: [
    .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
    .target(
      name: "UnisonCore",
      dependencies: ["CSQLite"],
      path: "ios/unison_native/Sources/unison_native/Core"
    ),
    .testTarget(
      name: "UnisonCoreTests",
      dependencies: ["UnisonCore"],
      path: "Tests/UnisonCoreTests",
      resources: [.copy("Fixtures")]
    ),
  ],
)
