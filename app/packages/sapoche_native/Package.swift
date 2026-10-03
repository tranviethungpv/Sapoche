// swift-tools-version: 5.9
// Development only: builds and tests the portable part of the iOS native side (ios/sapoche_native/Sources/sapoche_native/Core)
// on Linux, where there is no Xcode. The app itself builds from ios/sapoche_native/Package.swift.
import PackageDescription

let package = Package(
  name: "SapocheCore",
  products: [.library(name: "SapocheCore", targets: ["SapocheCore"])],
  targets: [
    .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
    .target(
      name: "SapocheCore",
      dependencies: ["CSQLite"],
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
