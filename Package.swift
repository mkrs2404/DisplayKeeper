// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DisplayKeeper",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DisplayKeeper", targets: ["DisplayKeeper"])],
    targets: [
        .target(name: "DisplayCore"),
        .target(name: "DisplayNative", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("QuartzCore"),
            .linkedFramework("ApplicationServices"), .linkedFramework("ColorSync"), .linkedFramework("IOKit")
        ]),
        .executableTarget(name: "DisplayKeeper", dependencies: ["DisplayCore", "DisplayNative"],
                          linkerSettings: [.linkedFramework("ServiceManagement")]),
        .testTarget(name: "DisplayCoreTests", dependencies: ["DisplayCore"])
    ],
    swiftLanguageModes: [.v5]
)
