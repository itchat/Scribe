<div align="center">

# Scribe

**Transcribe, translate, and burn subtitles into videos — 100% on your Mac.**

Plus a real-time Live Captions window that captions whatever you hear from your speakers.

[![CI](https://github.com/itchat/Scribe/actions/workflows/ci.yml/badge.svg)](https://github.com/itchat/Scribe/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![macOS 15+](https://img.shields.io/badge/macOS-15.0%2B-black?logo=apple)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange?logo=swift)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-optimized-purple)

</div>

---

## What it does

Drop a video in, pick an ASR engine, hit Start. The whole pipeline is local except for the optional translation API call.

```
video.mp4  →  audio.wav  →  transcript     →  translated SRT  →  subtitled video
              (ffmpeg)      (Parakeet on ANE,  (OpenAI / Google   (ffmpeg + libass)
                            Qwen3 0.6B/1.7B    / off)
                            on MLX with
                            forced aligner)
```

Or open Live Captions (⌘⇧L) and talk: it captures system audio with ScreenCaptureKit and streams a transcript into a notepad-shaped window in real time.

<p align="center">
  <img src=".github/assets/hero.png" alt="Scribe main window" width="720">
  <br>
  <sub><em>Drop videos, pick an engine, hit Start. Settings live in the native Inspector.</em></sub>
</p>

## Why I built it

I had a Python prototype using PyQt6 + MLX that shipped as a **~200 MB** PyInstaller bundle with a 3-second cold start and a UI that felt Linux-y on macOS. I wanted to see how far a modern Swift rewrite could go if it followed SOLID strictly and shipped a native UI.

**Result:** native UI, sub-second launch, then about a year of feature growth (Qwen3 ASR, Live Captions, customisable subtitle styling) on top of the same SOLID core.

## The numbers

| | Python (original) | Swift (Scribe) |
|---|---:|---:|
| App binary (Mach-O) | ~200 MB | **69 MB** |
| Cold launch | 2–5 s | **< 0.5 s** |
| ASR runtime | MLX (GPU) | CoreML (ANE) + MLX |
| Tests | 0 | **173** across 27 suites |
| Transcript languages | English | English (Parakeet) + 30+ via Qwen3 ASR |
| External dependencies | 6 | 2 SPM (FluidAudio + speech-swift) + 2 binary (sherpa-onnx + ONNX Runtime, fetched on demand) |

The full `.app` bundle is ~160 MB because it ships ffmpeg-full, dylibbundler-rewired Homebrew dylibs, the MLX Metal shader library, and an ad-hoc code signature so end users never have to install anything.

## Pair-programmed with Claude Code

Scribe was built end-to-end with **[Claude Code](https://claude.com/claude-code)** (Opus 4.7 · 1M context) as an experiment in AI pair programming. I drove the product decisions and reviewed every change; Claude wrote most of the code, suggested refactors, and caught its own SOLID violations when I asked for an audit.

The build followed strict **Red → Green → Refactor TDD**: 173 tests across 27 suites were written before the implementation they test. When the audit flagged `ProcessingViewModel` for juggling five responsibilities and a Dependency Inversion violation, the refactor split it into four focused services without breaking a single test.

## Architecture

```
UI (SwiftUI)
   │
   ▼
Core (pipeline, parsers, orchestration)
   │
   ▼
Protocols ◄── Infrastructure (FFmpeg, FluidAudio, MLX, sherpa-onnx, OpenAI, Google)
   │
   ▼
Domain (pure value types · zero imports)
```

Five SPM targets with strictly unidirectional dependencies. Zero singletons. The composition root assembles concrete types **exactly once** per pipeline run, so every component is replaceable and every layer is independently testable.

## Features

### Burn pipeline — speech recognition
User picks the engine in Settings; the pipeline injects the matching `SpeechRecognizing` conformer at runtime.

- **Parakeet TDT 0.6B v2** — English-only, [FluidAudio](https://github.com/FluidInference/FluidAudio) on the Apple Neural Engine. ~120× realtime on M4 Pro. Default.
- **Qwen3-ASR 0.6B (4-bit MLX)** — multilingual incl. zh/en code-switching. ~342 MB first-run download.
- **Qwen3-ASR 1.7B (4-bit MLX)** — same coverage, higher accuracy, ~3× the runtime. ~700 MB first-run download.

Both Qwen3 paths run on [soniqo/speech-swift](https://github.com/soniqo/speech-swift) (MLX-Swift). The companion **Qwen3-ForcedAligner-0.6B** model produces acoustic word-level timestamps so SRT cue boundaries land on real speech pauses; if alignment fails, the pipeline falls back to a char-weighted `SentenceChunker`.

### Live Captions (⌘⇧L)
A separate window that captures system audio via **ScreenCaptureKit** and streams a transcript into a notepad-shaped scroll view in real time.

- **Nemotron 0.6B** — true streaming (1.1 s latency), English-only
- **Zipformer zh-en** — sherpa-onnx bilingual transducer, ~300 ms latency, native code-switching

Toolbar exports the rolling transcript as SRT, plain text, or copies it to the clipboard. macOS Screen-Recording permission is requested on first start.

### Translation
- **Off / OpenAI / Google** — single 3-way picker; OpenAI mode reveals base URL / API key / model / system prompt / batching steppers
- **OpenAI**-compatible APIs (OpenAI, OpenRouter, Azure, local proxies — anything that speaks `/v1/chat/completions`)
- **Google Translate** free endpoint (no API key)
- **Decorator-pattern fallback**: if OpenAI fails, try Google; if both fail, keep originals
- Smart batch splitting with a multi-strategy separator-recovery heuristic for malformed responses

### Subtitle styling
- **Concrete `SubtitleStyle`** struct: font / size / colours / box style / vertical + horizontal margins. No preset abstraction layer — every field is directly editable.
- **macOS-bundled fonts only**: New York (default serif), Helvetica Neue, Times, Hiragino Sans GB. Resolved through libass via `fontsdir=/System/Library/Fonts`.
- ffmpeg's `subtitles` filter receives `original_size=WxH`, so `FontSize` is interpreted in real pixels rather than scaled against libass's implicit PlayResY=288 (the wall-of-text bug on portrait clips).
- Margins keep cues inside the canvas; libass auto-wraps before the edge.

### Video
- Audio extraction with optional **VideoToolbox** hardware acceleration
- Subtitle burn-in via FFmpeg's `subtitles` filter + `libass`
- Bilingual SRT side-car (`_en.srt`, `_bi.srt`)
- `ffmpeg-full` bundled in the release DMG so users never have to install it

### Native macOS UI
- SwiftUI `.toolbar`, `.inspector`, `.dropDestination`, `.regularMaterial`
- **Whole-window drop target** — drag more videos in over the queue, no dedicated drop bar
- **List(selection:) + ⌫** to remove the selected queued item
- Drag the finished `.mp4` back out to Finder, or the SRT side-car
- Video thumbnails, duration, resolution, file size (via `AVAssetImageGenerator`)
- **Settings auto-apply** — every control writes through on `.onChange`, no Apply button
- `ProcessingViewModel.addVideos` dedups against the existing queue
- System notifications on completion, transient toasts for in-session feedback

### Keyboard shortcuts
| | |
|---|---|
| `⌘O` | Open videos |
| `⌘R` | Start processing |
| `⌘⇧L` | Open Live Captions |
| `⌘,` | Toggle settings |
| `⌘⇧C` | Copy Live Captions transcript |
| `⌘⇧⌫` | Clear Live Captions |
| `⌫` | Remove selected queue item |
| `⌘Q` | Quit |

## Install

### From release

1. Download `Scribe-<version>.dmg` from the [Releases page](https://github.com/itchat/Scribe/releases)
2. Open the DMG, drag **Scribe** to Applications
3. First launch: right-click → **Open** (the build is ad-hoc signed, so Gatekeeper needs explicit permission once)

### From source

```bash
git clone https://github.com/itchat/Scribe.git
cd Scribe
brew install ffmpeg-full dylibbundler   # ffmpeg ships libass; dylibbundler rewires its dylibs
./scripts/fetch-sherpa-onnx.sh          # one-time: vendor sherpa-onnx + ONNX Runtime xcframeworks
swift run Scribe                        # dev run
./scripts/build-app.sh --dmg            # package .app + .dmg into dist/
```

`build-app.sh` also runs `scripts/build-mlx-metallib.sh` to compile MLX's Metal shaders into `Contents/MacOS/mlx.metallib` — without this, the Qwen3 engines crash at runtime with *"Failed to load the default metallib"*.

**Requirements:** macOS 15 (Sequoia) or later, Apple Silicon (M1+). Full Xcode is needed at build time (`xcrun metal` is not in the Command Line Tools).

## Design highlights

A few pieces I'm happy with:

**Pipeline is pure orchestration.** `VideoPipeline` has six injected protocol dependencies and knows nothing about FFmpeg, OpenAI, or CoreML. The `translationMode` and `skipSubtitleBurning` flags are independent — skipping translation alone still burns the original-language SRT into the video.

**Translator is a decorator.** `FallbackTranslator(primary: openAI, fallback: google)` conforms to the same protocol as its children. You can nest it arbitrarily without touching the pipeline.

**FFmpeg is three small types, not one big one.** A `Locator` that finds the binary, a `CommandBuilder` (pure functions, 100% unit-testable), and a `ProcessRunner` with timeout + stderr handling. Extractor and Probe each pick what they need — ISP in practice.

**Auto-save settings, all the way down.** The Inspector has no Apply button. Every control wires `.onChange` (not `.onSubmit`) so changes persist when focus moves away — not only on Enter. `ConfigService` loads from disk on `init` so SwiftUI views see persisted values on first body render.

**Subtitle timing is acoustic when possible.** Qwen3 path runs the audio + transcript through `Qwen3ForcedAligner` to get word-level timestamps, then `WordGroupingChunker` groups words into reading-shaped cues at sentence terminators. When alignment is unavailable, `SentenceChunker` distributes time proportionally to chunk character count — the standard heuristic from `aeneas` / WhisperX.

**Error handling is a single enum.** `ScribeError` has ~15 cases, each carrying just the data that case needs. One switch in the pipeline decides whether to retry, surface the error, or fail softly — no exception hierarchy, no `Any` casts.

## Tech stack

- **SwiftUI** (macOS 15+) with Swift 6 concurrency (`async/await`, `actor`)
- **[FluidAudio](https://github.com/FluidInference/FluidAudio)** — CoreML Parakeet + Nemotron streaming
- **[soniqo/speech-swift](https://github.com/soniqo/speech-swift)** — MLX-Swift port of Qwen3-ASR + Qwen3-ForcedAligner
- **[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)** — ONNX Runtime streaming Zipformer for zh-en
- **[FFmpeg](https://ffmpeg.org/)** (subprocess, bundled) — audio + video
- **[swift-testing](https://github.com/swiftlang/swift-testing)** — all 173 tests
- **ScreenCaptureKit** for live system-audio capture
- **URLSession** for HTTP; **Codable** + JSON for config persistence (`~/Library/Application Support/Scribe/`)

## Project layout

```
Scribe/
├── Package.swift                  # 5 targets, strict dependency graph
├── Sources/
│   ├── Domain/                    # value types, zero imports
│   ├── Protocols/                 # ~10 small interfaces
│   ├── Core/                      # pipeline, parsers, retry, batch
│   ├── Infrastructure/            # FFmpeg, ASR (9 files), translation, config
│   └── App/
│       ├── LiveCaptions/          # standalone ⌘⇧L window
│       ├── Services/              # ConfigService, ASRModelService, Toast, Notifier
│       ├── ViewModels/            # ProcessingViewModel, SettingsViewModel
│       └── Views/                 # ContentView, SettingsInspector, etc.
├── Tests/
│   ├── UnitTests/                 # Domain / Core / Infrastructure suites
│   └── IntegrationTests/          # VideoPipeline + Qwen3 E2E
├── scripts/
│   ├── build-app.sh               # release → .app → DMG
│   ├── build-mlx-metallib.sh      # xcrun metal → mlx.metallib next to binary
│   ├── fetch-sherpa-onnx.sh       # vendor sherpa-onnx + ONNX Runtime xcframeworks
│   ├── setup-signing-cert.sh      # generate stable self-signed cert (TCC-friendly)
│   └── make-icon.sh               # regenerate the app icon from SF Symbols
├── .github/workflows/             # CI on push; Release on tag
└── Resources/                     # Info.plist, AppIcon.icns
```

## Releasing

```bash
git tag v1.1.0
git push origin v1.1.0
```

GitHub Actions tests → builds → attaches `Scribe-v1.1.0.app.zip` + `Scribe-v1.1.0.dmg` to the release.

## License

MIT. See [LICENSE](LICENSE).

---

<div align="center">
<sub>Built by <a href="https://github.com/itchat">@itchat</a> with <a href="https://claude.com/claude-code">Claude Code</a> (Opus 4.7 · 1M context).</sub>
</div>
