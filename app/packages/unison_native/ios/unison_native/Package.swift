// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "unison_native",
  platforms: [
    .iOS("15.0")
  ],
  products: [
    .library(name: "unison-native", targets: ["unison_native"])
  ],
  dependencies: [],
  targets: [
    .target(
      name: "unison_native",
      dependencies: [],
      linkerSettings: [.linkedLibrary("sqlite3")]
    )
  ]
)
