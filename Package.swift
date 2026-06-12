// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "JarveyNative",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(
      name: "JarveyNative",
      targets: ["JarveyNative"]
    )
  ],
  targets: [
    .executableTarget(
      name: "JarveyNative",
      path: "Sources/JarveyNative",
      resources: [.process("Resources")]
    ),
    .testTarget(
      name: "JarveyNativeTests",
      dependencies: ["JarveyNative"],
      path: "Tests/JarveyNativeTests"
    )
  ]
)
