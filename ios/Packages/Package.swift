// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Slowmail",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SlowmailCore", targets: ["SlowmailCore"]),
        .library(name: "SlowmailUI", targets: ["SlowmailUI"]),
    ],
    targets: [
        .target(name: "SlowmailCore"),
        .target(name: "SlowmailUI", dependencies: ["SlowmailCore"]),
        .executableTarget(name: "Screenshots", dependencies: ["SlowmailUI", "SlowmailCore"]),
        .testTarget(name: "SlowmailCoreTests", dependencies: ["SlowmailCore", "SlowmailUI"]),
    ]
)
