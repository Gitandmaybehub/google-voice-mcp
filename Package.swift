// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "gvoice",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "gvoice", targets: ["gvoice"])],
    targets: [
        .target(name: "GVoiceKit"),
        .executableTarget(name: "gvoice", dependencies: ["GVoiceKit"]),
        .testTarget(name: "GVoiceKitTests", dependencies: ["GVoiceKit"]),
    ]
)
