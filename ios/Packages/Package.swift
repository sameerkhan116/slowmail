// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Slowmail",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SlowmailCore", targets: ["SlowmailCore"]),
        .library(name: "SlowmailUI", targets: ["SlowmailUI"]),
    ],
    dependencies: [
        .package(path: "MailClockKit"),
    ],
    targets: [
        .target(
            name: "SlowmailCore",
            dependencies: [
                .product(name: "MailClockKit", package: "MailClockKit"),
            ]
        ),
        .target(name: "SlowmailUI", dependencies: ["SlowmailCore"]),
        .executableTarget(name: "Screenshots", dependencies: ["SlowmailUI", "SlowmailCore"]),
        .testTarget(
            name: "SlowmailCoreTests",
            dependencies: [
                "SlowmailCore",
                "SlowmailUI",
                .product(name: "MailClockKit", package: "MailClockKit"),
            ]
        ),
    ]
)
