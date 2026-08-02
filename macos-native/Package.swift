// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VEXNativeMac",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "VEXNativeMac", targets: ["VEXNativeMac"]),
        .executable(name: "VEXPrivilegedHelper", targets: ["VEXPrivilegedHelper"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
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
        .target(
            name: "VEXHelperCore",
            path: "Sources/VEXHelperCore",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedLibrary("bsm"),
            ]
        ),
        .executableTarget(
            name: "VEXPrivilegedHelper",
            dependencies: ["VEXHelperCore"],
            path: "Sources/VEXPrivilegedHelper"
        ),
        .testTarget(
            name: "VEXNativeMacTests",
            dependencies: ["VEXNativeMac", "VEXHelperCore"],
            path: "Tests/VEXNativeMacTests"
        ),
        .testTarget(
            name: "VEXPrivilegedHelperTests",
            dependencies: ["VEXHelperCore"],
            path: "Tests/VEXPrivilegedHelperTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
