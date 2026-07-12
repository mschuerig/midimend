// swift-tools-version:6.0
// Tools 6.0 is the floor that supports swiftLanguageMode(.v6); staying
// there lets Xcode 16.x build the package (CI runners, brew users) —
// nothing here needs a newer toolchain.
import PackageDescription

let package = Package(
    name: "midimend",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "midimend", targets: ["midimend-cli"]),
        .library(name: "Midimend", targets: ["Midimend"]),
    ],
    targets: [
        .target(
            name: "Midimend",
            resources: [
                // Compiled into the binary: keeps the executable
                // single-file (nothing to find at runtime, one Mach-O to
                // sign and notarize).
                .embedInCode("Resources/Bootstrap.js")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "midimend-cli",
            dependencies: ["Midimend"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MidimendTests",
            dependencies: ["Midimend"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
