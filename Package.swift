// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "GPXCreator", platforms: [.macOS(.v14)], products: [.executable(name: "GPXCreator", targets: ["GPXCreator"])], targets: [.executableTarget(name: "GPXCreator", resources: [.copy("Resources")]), .testTarget(name: "GPXCreatorTests", dependencies: ["GPXCreator"])])
