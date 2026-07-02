// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VEXNativeMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "VEXNativeMac", targets: ["VEXNativeMac"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.3")
    ],
    targets: [
        .executableTarget(
            name: "VEXNativeMac",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/VEXNativeMac",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "VEXNativeMacTests",
            dependencies: ["VEXNativeMac"],
            path: "Tests/VEXNativeMacTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
