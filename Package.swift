// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Burrow",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Burrow", targets: ["Burrow"])
    ],
    targets: [
        .executableTarget(
            name: "Burrow",
            path: "Sources/Burrow",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("CoreServices"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        )
    ]
)
