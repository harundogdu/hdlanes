// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "hdlanes",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "hdlanes", targets: ["HDLanes"]),
        .executable(name: "hdlanes-hook", targets: ["HDHook"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.2"),
    ],
    targets: [
        // Pure logic: models, persistence, env building, event reducers, parsers. No AppKit.
        .target(name: "HDCore", path: "Sources/HDCore"),
        // Tiny CLI that Claude Code hooks and the status line call; forwards JSON to the app's socket.
        .executableTarget(name: "HDHook", dependencies: ["HDCore"], path: "Sources/HDHook"),
        // The macOS app. Swift 5 mode because SwiftTerm's delegates are not annotated for Swift 6 isolation.
        .executableTarget(
            name: "HDLanes",
            dependencies: ["HDCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/HDLanes",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "HDCoreTests", dependencies: ["HDCore"], path: "Tests/HDCoreTests"),
    ]
)
