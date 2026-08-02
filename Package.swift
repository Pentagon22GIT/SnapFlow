// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SnapFlow",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SnapFlow", targets: ["SnapFlow"])],
    targets: [
        .executableTarget(
            name: "SnapFlow",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "SnapFlowTests",
            dependencies: ["SnapFlow"]
        )
    ]
)
