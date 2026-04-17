// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Scribe",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Scribe", targets: ["App"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.2.4"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.9.0"),
    ],
    targets: [
        // ── Domain: Pure value types, zero dependencies ──
        .target(
            name: "Domain",
            path: "Sources/Domain"
        ),

        // ── Protocols: Abstract interfaces, depends only on Domain ──
        .target(
            name: "Protocols",
            dependencies: ["Domain"],
            path: "Sources/Protocols"
        ),

        // ── Core: Business logic, depends on Protocols + Domain ──
        .target(
            name: "Core",
            dependencies: ["Domain", "Protocols"],
            path: "Sources/Core"
        ),

        // ── Infrastructure: Concrete implementations, depends on Protocols + Domain + FluidAudio ──
        .target(
            name: "Infrastructure",
            dependencies: [
                "Domain", "Protocols",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Infrastructure"
        ),

        // ── App: Composition Root + SwiftUI, depends on everything ──
        .executableTarget(
            name: "App",
            dependencies: ["Domain", "Protocols", "Core", "Infrastructure"],
            path: "Sources/App"
        ),

        // ── Tests ──
        .testTarget(
            name: "DomainTests",
            dependencies: [
                "Domain",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/UnitTests/Domain"
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: [
                "Core", "Domain", "Protocols",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/UnitTests/Core"
        ),
        .testTarget(
            name: "InfrastructureTests",
            dependencies: [
                "Infrastructure", "Domain", "Protocols",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/UnitTests/Infrastructure"
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "Core", "Infrastructure", "Domain", "Protocols",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/IntegrationTests"
        ),
    ]
)
