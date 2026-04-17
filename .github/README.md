# CI/CD Workflows

## Workflows

### `ci.yml` — Tests on every push/PR to `main`

Runs `swift test` on a macOS 14 (Apple Silicon) runner. Fast feedback for PRs.

### `release.yml` — Build & release on version tags

Triggered by:
- **Pushing a tag** matching `v*` (e.g. `v1.0.0`, `v1.2.3-beta`)
- **Manual dispatch** from the Actions UI (no release, just artifacts)

Produces:
- `Scribe-<version>.app.zip` — zipped .app bundle
- `Scribe-<version>.dmg` — DMG installer

When triggered by a tag, files are attached to a GitHub Release. When triggered manually, files are uploaded as workflow artifacts (30-day retention).

## How to cut a release

```bash
# Make sure main is clean, all tests pass
git tag v1.0.0
git push origin v1.0.0
```

GitHub Actions will:
1. Run all tests
2. Build release .app with bundled ffmpeg-full (has libass)
3. Create .app.zip and .dmg artifacts
4. Create a GitHub Release with auto-generated release notes
5. Attach both files to the release

Users download the .dmg from the Releases page.

## Gatekeeper note

Without an Apple Developer ID, builds are **ad-hoc signed**. Users will see a
Gatekeeper warning on first launch and must right-click → **Open** to confirm.

To eliminate this, add `APPLE_DEVELOPER_ID_CERT` and `APPLE_DEVELOPER_ID_PASSWORD`
repository secrets and extend `release.yml` with code-signing + notarization steps.
