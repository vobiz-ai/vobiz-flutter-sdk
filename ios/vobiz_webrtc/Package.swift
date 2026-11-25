// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "vobiz_webrtc",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "vobiz-webrtc", targets: ["vobiz_webrtc"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "vobiz_webrtc",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
