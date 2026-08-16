// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MailClockKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "MailClockKit", targets: ["MailClockKit"]),
    ],
    targets: [
        .target(name: "MailClockKit"),
        .testTarget(
            name: "MailClockKitTests",
            dependencies: ["MailClockKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
