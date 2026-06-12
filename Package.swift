// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "JarvisNative",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(
      name: "JarvisNative",
      targets: ["JarvisNative"]
    )
  ],
  targets: [
    .executableTarget(
      name: "JarvisNative",
      path: "Sources/JarvisNative",
      resources: [.process("Resources")]
    ),
    .testTarget(
      name: "JarvisNativeTests",
      dependencies: ["JarvisNative"],
      path: "Tests/JarvisNativeTests"
    )
  ]
)
