// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "SimpleCut",
    platforms: [.macOS(.v14)],
  products: [
    .executable(name: "SimpleCut", targets: ["SimpleCut"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/argmaxinc/argmax-oss-swift.git",
      from: "0.9.0"
    )
  ],
  targets: [
    .executableTarget(
      name: "SimpleCut",
      dependencies: [
        .product(name: "WhisperKit", package: "argmax-oss-swift")
      ],
      path: "Sources/SimpleCut"
    ),
        .testTarget(
            name: "SimpleCutTests",
            dependencies: ["SimpleCut"],
            path: "Tests/SimpleCutTests"
        )
    ]
)
