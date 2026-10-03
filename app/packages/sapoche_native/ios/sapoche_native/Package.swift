// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "sapoche_native",
  platforms: [
    .iOS("15.0")
  ],
  products: [
    .library(name: "sapoche-native", targets: ["sapoche_native"])
  ],
  dependencies: [],
  targets: [
    .target(
      name: "sapoche_native",
      dependencies: [],
      linkerSettings: [.linkedLibrary("sqlite3")]
    )
  ]
)
