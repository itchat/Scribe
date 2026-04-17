# Scribe

> Transcribe, translate, and burn bilingual subtitles into videos — all locally on your Mac.

Scribe is a native macOS utility that takes a video, transcribes its audio, translates the transcript, and optionally burns bilingual subtitles back into the video. Everything runs on-device: the ASR model uses Apple's Neural Engine, and FFmpeg handles the video work locally. The only outbound traffic is to your chosen translation API.

This project was **pair-programmed with [Claude Code](https://claude.com/claude-code) (Opus 4.7 · 1M context)** as an exercise in applying:

- **Strict SOLID principles** across a 5-layer architecture (Domain → Protocols → Core → Infrastructure → App)
- **Test-Driven Development** with 115 tests written before the implementation
- **Native macOS UI/UX** matching Apple Human Interface Guidelines (Inspector panels, toolbar commands, system notifications, SF Symbols, materials)

Scribe is a rewrite of an earlier Python/PyQt6 prototype — the Swift version is **~60% smaller in code**, **~95% smaller in binary**, launches instantly, and uses the Neural Engine instead of the GPU for ASR.

---

## Features

### Speech Recognition (Local)
- **Parakeet TDT 0.6B v2** (English) compiled to CoreML, running on the Apple Neural Engine
- ~120× realtime on M-series chips
- Powered by [FluidAudio](https://github.com/FluidInference/FluidAudio)
- Model auto-downloads on first use (~1.2 GB)

### Translation
- **OpenAI** (configurable Base URL, API Key, Model, System Prompt) — supports OpenRouter, Azure, local proxies, etc.
- **Google Translate** (free web API, no key required)
- **Automatic fallback**: OpenAI failure → Google
- Smart batch splitting with separator-recovery heuristics

### Video Processing
- Audio extraction via FFmpeg (optional VideoToolbox hardware acceleration)
- Hardsub burn-in using `subtitles` filter + `libass` (via bundled `ffmpeg-full`)
- Bilingual SRT output (`_en.srt` + `_bi.srt`) alongside source video

### Native macOS UI
- SwiftUI with `.toolbar`, `.inspector`, `.regularMaterial`
- Drag-and-drop with `.dropDestination`
- Video thumbnails, duration, resolution, file size
- Settings auto-apply (no Apply button — matches Xcode/Keynote/Finder)
- System notifications on completion
- Transient toast feedback
- Draggable video rows (drag output .mp4 straight to Finder)
- Custom app icon
- True fullscreen (`.fullScreenPrimary`)

### Keyboard Shortcuts
| Shortcut | Action |
|----------|--------|
| ⌘O | Open video files |
| ⌘R | Start processing |
| ⌘, | Toggle settings inspector |
| ⌘Q | Quit |

---

## Architecture

```
UI (SwiftUI) ──► Core (business logic) ──► Protocols ◄── Infrastructure (FFmpeg, ASR, Translation)
                                              │
                                           Domain (pure value types)
```

5 SPM targets enforce a strict dependency direction. The App layer is the only Composition Root.

- **Domain** — `SubtitleEntry`, `SubtitleTimestamp`, `TranscriptionResult`, `ScribeError`, `Constants`
- **Protocols** — 7 small, focused interfaces (`AudioExtracting`, `AudioProbing`, `SpeechRecognizing`, `SubtitleTranslating`, `SubtitleFormatting`, `VideoComposing`, `ProgressReporting`)
- **Core** — `SRTParser`, `SRTWriter`, `BatchSplitter`, `ResponseRecovery`, `RetryExecutor`, `VideoPipeline`, `ProcessingQueue`, `SubtitleFormatter`
- **Infrastructure** — FFmpeg (Locator, CommandBuilder, ProcessRunner, AudioExtractor, AudioProbe, VideoComposer), Translation (OpenAI, Google, Fallback decorator, RequestBuilder), ASR (FluidAudioRecognizer), Config (AppConfig)
- **App** — SwiftUI views, ViewModels, Services (ASRModel, Config, Toast, SystemNotifier)

---

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon (M1 or later) recommended — ASR requires Neural Engine
- `ffmpeg-full` is bundled in the release DMG (has `libass` for subtitle burning)

---

## Installation

### From Release (Recommended)

1. Download the latest `Scribe-<version>.dmg` from the [Releases page](https://github.com/itchat/Scribe/releases)
2. Open the DMG and drag **Scribe** to Applications
3. Right-click the app → **Open** on first launch (app is ad-hoc signed without Apple Developer ID)

### From Source

```bash
git clone https://github.com/itchat/Scribe.git
cd Scribe

# Install ffmpeg-full (has libass for subtitle burning)
brew install ffmpeg-full

# Build and run
swift run Scribe

# Or build a distributable .app + DMG
./scripts/build-app.sh --dmg
```

---

## Usage

1. **Drop videos** onto the window (MP4, AVI, MOV, MKV, FLV, WMV)
2. **Configure translation** (⌘,) — pick OpenAI or Google, set API key if needed
3. **Download the ASR model** via the toolbar (first time only, ~1.2 GB)
4. **Start Processing** (⌘R)
5. Drag the output video row directly to Finder when done

---

## Development

### Project Structure

```
Scribe/
├── Package.swift
├── Sources/
│   ├── App/              # SwiftUI views + ViewModels + Services
│   ├── Domain/           # Pure value types (zero imports)
│   ├── Protocols/        # Abstract interfaces
│   ├── Core/             # Business logic (depends on Domain + Protocols)
│   └── Infrastructure/   # FFmpeg, ASR, Translation, Config
├── Tests/
│   ├── UnitTests/
│   └── IntegrationTests/
├── Resources/            # Info.plist, AppIcon.icns
├── scripts/
│   ├── build-app.sh      # Release build → .app → DMG
│   └── make-icon.sh      # Regenerate app icon
└── .github/workflows/    # CI (tests) + Release (tag-triggered builds)
```

### Running Tests

```bash
swift test
```

115 tests across 19 suites covering SRT parsing, batch splitting, retry logic, response recovery, translation, pipeline orchestration, and more.

### Cutting a Release

```bash
git tag v1.0.0
git push origin v1.0.0
```

GitHub Actions will build and attach `Scribe-<version>.app.zip` + `.dmg` to the release automatically.

---

## Tech Stack

| Layer | Choice |
|-------|--------|
| UI | SwiftUI (macOS 14+) |
| Concurrency | Swift 6 async/await + actors |
| ASR | [FluidAudio](https://github.com/FluidInference/FluidAudio) (Parakeet TDT CoreML on ANE) |
| Video | FFmpeg CLI (subprocess) |
| Testing | [swift-testing](https://github.com/swiftlang/swift-testing) |
| Translation | `URLSession` (OpenAI chat/completions + Google Translate web API) |
| Persistence | `Codable` + JSON file (`~/Library/Application Support/Scribe/`) |

---

## Credits

- [FluidAudio](https://github.com/FluidInference/FluidAudio) — CoreML Parakeet ASR
- [FFmpeg](https://ffmpeg.org/) — audio/video processing
- [OpenAI](https://openai.com/) — translation API

Pair-programmed with [Claude Code](https://claude.com/claude-code) using Opus 4.7 (1M context).

---

## License

MIT
