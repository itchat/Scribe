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
        // swift-testing is NOT declared here: Swift 6 ships `Testing` in the
        // toolchain, so test targets just `import Testing`. Depending on the
        // package as well pinned us to a swift-syntax that had to stay
        // compatible with a floating Xcode, and upstream no longer publishes
        // semver tags (only `swift-X.Y.Z-RELEASE`), so the old
        // `exact: "6.2.4"` pin had no forward path.
        //
        // FluidAudio is 0.x, where minor bumps are breaking, so pin to the
        // next minor rather than `from:` — `from: "0.9.0"` silently allowed
        // anything below 1.0 and would jump two minor series on any
        // unattended `swift package update`.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.15.5")),
        // soniqo/speech-swift exposes Qwen3-ASR (0.6B + 1.7B) on Apple Silicon
        // via MLX-Swift. The package itself targets macOS 15 (uses MLState API),
        // so all call sites are gated with `@available(macOS 15, *)` and our
        // app deployment target stays at macOS 14.
        // Kept as `exact:` deliberately. 0.0.x carries no semver guarantee,
        // so a range would let unattended resolution pull breaking API
        // changes into both Infrastructure and the test targets (which
        // import Qwen3ASR/SpeechVAD types directly).
        .package(url: "https://github.com/soniqo/speech-swift.git", exact: "0.0.23"),
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
                "Domain", "Protocols", "Core",
                .product(name: "FluidAudio", package: "FluidAudio"),
                "CSherpaOnnx",
                "OnnxRuntime",
                .product(name: "Qwen3ASR", package: "speech-swift"),
                // SpeechVAD ships Silero VAD which we use to segment the
                // continuous SCStream audio into speech runs for the
                // Qwen3-ASR Live Captions engine — speech-swift's own
                // `StreamingASR` class takes a complete buffer upfront and
                // can't be driven push-style, so we reuse its VAD bricks
                // and run our own actor-buffered loop.
                .product(name: "SpeechVAD", package: "speech-swift"),
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
            ],
            path: "Tests/UnitTests/Domain"
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: [
                "Core", "Domain", "Protocols",
            ],
            path: "Tests/UnitTests/Core"
        ),
        .testTarget(
            name: "InfrastructureTests",
            dependencies: [
                "Infrastructure", "Domain", "Protocols",
                // For WordGroupingChunkerTests — we need AlignedWord (in
                // AudioCommon, transitively re-exported by Qwen3ASR).
                .product(name: "Qwen3ASR", package: "speech-swift"),
                // For Qwen3SegmentPlannerTests — VADEvent / SpeechSegment
                // live in SpeechVAD and AudioCommon respectively.
                .product(name: "SpeechVAD", package: "speech-swift"),
            ],
            path: "Tests/UnitTests/Infrastructure"
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "Core", "Infrastructure", "Domain", "Protocols",
            ],
            path: "Tests/IntegrationTests"
        ),
    ]
)
