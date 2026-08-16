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
            dependencies: ["MailClockKit"],
            swiftSettings: [
                .unsafeFlags([
                    "-F",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-L/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                    "-l_TestingInterop",
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ]),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
