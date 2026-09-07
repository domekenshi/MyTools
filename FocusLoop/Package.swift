// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FocusLoop",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "FocusLoop", targets: ["FocusLoop"])],
    targets: [.executableTarget(name: "FocusLoop")]
)
