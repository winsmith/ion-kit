// swift-tools-version: 6.2
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
        .target(name: "IonKit"),
        .target(name: "IonKitTesting", dependencies: ["IonKit"]),
        .testTarget(
            name: "IonKitTests",
            dependencies: ["IonKit", "IonKitTesting"],
            resources: [.copy("Resources")]
        ),
    ]
)
