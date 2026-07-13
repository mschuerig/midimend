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
        // Named MidimendCore, not Midimend: on a case-insensitive filesystem
        // a library target "Midimend" collides with the executable product
        // "midimend" in Xcode's build intermediates (midimend.build vs
        // Midimend.build are the same dir), scrambling the module's source
        // list. swift build is unaffected; Xcode is not.
        .library(name: "MidimendCore", targets: ["MidimendCore"]),
    ],
    targets: [
        .target(
            name: "MidimendCore",
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
            dependencies: ["MidimendCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MidimendTests",
            dependencies: ["MidimendCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
