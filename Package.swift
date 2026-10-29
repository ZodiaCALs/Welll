// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Welll",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Welll", targets: ["Welll"]),
        .executable(name: "wellld", targets: ["wellld"]),
        .executable(name: "welllctl", targets: ["welllctl"]),
    ],
    targets: [
        // C and Objective-C shims: the AppleSMC user client and macOS's private
        // charge-limit client (PowerUI).
        .target(
            name: "CWelll",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Foundation"),
            ]
        ),
        // Models, the XPC protocol and the battery / SMC readers shared by all three programs.
        .target(
            name: "WelllCore",
            dependencies: ["CWelll"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // Root LaunchDaemon that enforces the limit.
        .executableTarget(
            name: "wellld",
            dependencies: ["WelllCore", "CWelll"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        // Menu bar app.
        .executableTarget(
            name: "Welll",
            dependencies: ["WelllCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("IOKit"),
            ]
        ),
        // Command-line control and diagnostics.
        .executableTarget(
            name: "welllctl",
            dependencies: ["WelllCore", "CWelll"]
        ),
    ]
)
