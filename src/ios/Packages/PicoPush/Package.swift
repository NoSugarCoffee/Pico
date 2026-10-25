// swift-tools-version: 6.0
import PackageDescription

// Shared by the app and PicoNotificationService, which must stay small: no dependencies beyond the SDK.
let package = Package(
    name: "PicoPush",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [
        .library(name: "PicoPush", targets: ["PicoPush"]),
    ],
    targets: [
        .target(name: "PicoPush"),
        .testTarget(name: "PicoPushTests", dependencies: ["PicoPush"]),
    ],
    swiftLanguageModes: [.v6]
)
