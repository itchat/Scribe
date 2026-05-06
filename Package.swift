// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Scribe",
    platforms: [
        // macOS 15 (Sequoia) is required by the speech-swift package, which
        // uses Apple's MLState API for persistent ANE state across token
        // steps. Bumping here lets us use Qwen3-ASR (0.6B / 1.7B) for the
        // burn pipeline without per-callsite @available guards.
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Scribe", targets: ["App"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.2.4"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.9.0"),
        // soniqo/speech-swift exposes Qwen3-ASR (0.6B + 1.7B) on Apple Silicon
        // via MLX-Swift. The package itself targets macOS 15 (uses MLState API),
        // so all call sites are gated with `@available(macOS 15, *)` and our
        // app deployment target stays at macOS 14.
        .package(url: "https://github.com/soniqo/speech-swift.git", exact: "0.0.12"),
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

        // ── sherpa-onnx C API exposed as a Clang module ──
        // Both .xcframeworks plus the module.modulemap are produced by
        // scripts/fetch-sherpa-onnx.sh (gitignored under vendor/). ONNX
        // Runtime is required separately because libsherpa-onnx.a leaves
        // its OrtGetApiBase symbols as undefined externs.
        // Run that script after cloning the repo, before swift build.
        .binaryTarget(
            name: "CSherpaOnnx",
            path: "vendor/sherpa-onnx.xcframework"
        ),
        .binaryTarget(
            name: "OnnxRuntime",
            path: "vendor/onnxruntime.xcframework"
        ),

        // ── Infrastructure: Concrete implementations ──
        .target(
            name: "Infrastructure",
            dependencies: [
                "Domain", "Protocols",
                .product(name: "FluidAudio", package: "FluidAudio"),
                "CSherpaOnnx",
                "OnnxRuntime",
                .product(name: "Qwen3ASR", package: "speech-swift"),
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
                // For WordGroupingChunkerTests — we need AlignedWord (in
                // AudioCommon, transitively re-exported by Qwen3ASR).
                .product(name: "Qwen3ASR", package: "speech-swift"),
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
