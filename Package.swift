// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MXSwitch",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "mxswitchd", targets: ["mxswitchd"]),
        .executable(name: "MXSwitchApp", targets: ["MXSwitchApp"]),
        .executable(name: "mxswitch-tests", targets: ["mxswitch-tests"]),
    ],
    targets: [
        .target(name: "MXSwitchKit"),
        .executableTarget(name: "mxswitchd", dependencies: ["MXSwitchKit"]),
        .executableTarget(name: "MXSwitchApp", dependencies: ["MXSwitchKit"]),
        .executableTarget(name: "mxswitch-tests", dependencies: ["MXSwitchKit"]),
    ]
)
