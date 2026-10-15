// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IonKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "IonKit", targets: ["IonKit"]),
        .library(name: "IonKitTesting", targets: ["IonKitTesting"]),
    ],
    targets: [
        .target(
            name: "IonKit",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "IonKitTesting",
            dependencies: ["IonKit"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "IonKitTests",
            dependencies: ["IonKit", "IonKitTesting"],
            resources: [.copy("Resources")],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
    ]
)
