# LocalScribe

**Private, on-device meeting transcription for macOS with Apple Intelligence**

LocalScribe captures audio from meeting apps (Zoom, Google Meet, etc.), transcribes it locally using Whisper.cpp, and generates structured summaries using Apple Intelligence. Everything happens on your device—no data is sent to external servers.

## Features

- **System Audio + Microphone Capture** - Records both sides of your meetings via ScreenCaptureKit
- **Local Transcription** - Whisper.cpp large-v3-turbo multilingual model with automatic language detection, including mixed-language recordings (bundled with app, no downloads needed)
- **Speaker Diarization** - On-device Sortformer model labels up to 4 speakers, using the separate microphone and system audio tracks to identify you
- **Apple Intelligence Summarization** - 3-pass hierarchical summarization with structured markdown output
- **Encrypted Storage** - AES-256-GCM encryption for all transcripts, keys stored in macOS Keychain
- **Zero Network Access** - No external API calls, no telemetry, no analytics

## Requirements

- **macOS 26 (Tahoe)** or later
- **Apple Silicon** (M1, M2, M3, M4, or newer)
- **Apple Intelligence** downloaded and enabled in System Settings
- ~1GB disk space

## Installation

1. Download `LocalScribe-v0.3.0-beta.zip` from [GitHub Releases](https://github.com/harrykeen18/localscribe/releases)
2. **Verify checksum** (recommended):
   ```bash
   shasum -a 256 -c LocalScribe-v0.3.0-beta.zip.sha256
   # Should output: LocalScribe-v0.3.0-beta.zip: OK
   ```
3. Extract the .zip file
4. Move `LocalScribe.app` to `/Applications`
5. Open LocalScribe (signed with Developer ID and notarized by Apple)
6. Grant **Microphone** and **Screen Recording** permissions when prompted

### Updating from v0.2.x

Replace the old `LocalScribe.app` in `/Applications` with the new one. Your transcripts are kept.

Because this release is the first signed with a Developer ID certificate, macOS treats it as a new app once:

- When asked whether LocalScribe can use its key in your Keychain, click **Always Allow**. This key decrypts your existing transcripts.
- Grant **Microphone** and **Screen Recording** again. If recording still fails, remove the old LocalScribe entry under System Settings → Privacy & Security → Screen & System Audio Recording, then add it again.

If the Keychain prompt is denied, no transcripts are lost: LocalScribe sets the unreadable history aside and restores it on the next launch where the key can be read.

## Usage

1. Click the record button to start capturing
2. Have your meeting (Zoom, Google Meet, etc.)
3. Click stop when finished
4. Wait for transcription and summarization (~30-60 seconds)
5. View your structured summary and full transcript

## Privacy

### Zero Data Collection

LocalScribe collects **no data**. Nothing is sent to external servers.

- ✅ **On-device transcription**: Whisper.cpp runs locally, no network access
- ✅ **On-device summarization**: Apple Intelligence processes everything locally
- ✅ **Encrypted storage**: AES-256-GCM with keys in macOS Keychain
- ✅ **No network code**: Search the codebase—no URLSession, no API calls
- ✅ **No telemetry**: Zero analytics, crash reports, or tracking

### Technical Verification

Verify privacy claims yourself:

```bash
# Check Info.plist (should NOT contain NSAllowsArbitraryLoads)
grep "NSAllowsArbitraryLoads" LocalScribe.app/Contents/Info.plist

# Monitor network (app should make ZERO requests)
sudo nettop -p $(pgrep -x "LocalScribe")

# Search source code for network calls
grep -r "URLSession\|URLRequest" --include="*.swift"
```

### What We Don't Collect

- ❌ Meeting recordings
- ❌ Transcripts or summaries
- ❌ User behavior analytics
- ❌ Crash reports (unless you manually export diagnostics)
- ❌ Device identifiers or IP addresses

### Data Storage

Transcripts stored locally at:
```
~/Library/Containers/transcribe-offline/Data/Library/Application Support/AudioNotes/history.json
```

- **Encrypted**: AES-256-GCM before writing to disk
- **Keys**: Stored securely in macOS Keychain
- **Sandboxed**: App runs in a security container for additional protection
- **iCloud**: Not synced by default (container is local-only)

### Uninstalling

1. Move app to Trash
2. Delete app container (includes all transcripts and settings):
   ```bash
   rm -rf ~/Library/Containers/transcribe-offline/
   ```
3. Delete Keychain entries: Open Keychain Access, search for "com.transcribe", delete all entries

## Security

### Reporting Vulnerabilities

**DO NOT open public issues for security vulnerabilities.**

Please report security issues via GitHub Security Advisories:
https://github.com/harrykeen18/localscribe/security/advisories/new

Include:
- Detailed description and steps to reproduce
- Potential impact
- Suggested fix (if you have one)

### What Qualifies as a Security Issue

**In scope:**
- Data leakage (transcripts, audio, encryption keys)
- Unintended network requests
- Encryption implementation flaws
- Keychain access bypass
- File system access outside app container

**Out of scope:**
- Physical access attacks (if attacker has your Mac password)
- Social engineering
- Non-security bugs or feature requests

### Responsible Disclosure

We request:
- Reasonable time to fix before public disclosure (prefer 90-day window)
- Good faith security research

We promise:
- Acknowledgment within 48 hours
- Public credit (with your permission)
- No legal action against good-faith researchers

### Security Measures

- **Encryption**: AES-256-GCM for all transcripts
- **Keychain**: Encryption keys protected by your login password/Touch ID
- **No Network**: Info.plist blocks HTTP requests
- **Input Validation**: File paths sanitized, user input validated
- **Minimal Dependencies**: Whisper.cpp and FluidAudio (on-device speaker diarization)

### Known Limitations (Beta)

- ⚠️ **No key recovery**: If encryption key is lost, transcripts cannot be decrypted

### Threat Model

**LocalScribe protects against:**
- ✅ Network interception (no data sent)
- ✅ Disk forensics (encrypted at rest)
- ✅ Cloud provider access (no cloud services)
- ✅ App Store tracking (no telemetry)

**LocalScribe does NOT protect against:**
- ❌ Physical access with your Mac password (attacker can access Keychain)
- ❌ Malware with root access
- ❌ Memory dumps while app is running (transcripts unencrypted in RAM during use)

**Recommended additional protections:**
- Enable FileVault (full disk encryption)
- Use a strong Mac password
- Keep macOS updated
- Review app permissions regularly (System Settings → Privacy & Security)

## Building from Source

1. Clone the repository:
   ```bash
   git clone https://github.com/harrykeen18/localscribe.git
   cd localscribe
   git checkout stable
   ```

2. **Get the bundled models and Whisper executable**:
   - Download the release .zip from the [latest release](https://github.com/harrykeen18/localscribe/releases/latest)
   - Copy `whisper`, `base.en.bin`, `ggml-large-v3-turbo-q5_0.bin` and `SortformerNvidiaHigh_v2.1.mlmodelc` from `LocalScribe.app/Contents/Resources/` into a `Resources/` directory in the repository
   - Or build the Whisper executable yourself with `./build-whisper.sh`

3. Open in Xcode:
   ```bash
   open transcribe-offline.xcodeproj
   ```

4. Build: Product → Build (⌘B)

5. Run: Product → Run (⌘R)

## Bug Reports

This is beta software. Bugs are expected!

### How to Report

1. **Export Diagnostics**:
   - Open Settings (gear icon)
   - Scroll to "Diagnostics" section
   - Click "Copy to Clipboard" or "Save to File"

2. **Create GitHub Issue**:
   - Open [GitHub Issues](https://github.com/harrykeen18/localscribe/issues)
   - Describe the problem
   - Paste diagnostics
   - **Note**: Diagnostics contain NO transcript content—only logs and system info

### What to Include

- Steps to reproduce
- Expected vs. actual behavior
- Diagnostics export
- macOS version and chip type

## Known Issues

- Very long recordings (>2 hours) may fail due to memory constraints
- First summarization may be slow (~30-60s) as Apple Intelligence initializes
- Apple Intelligence must be downloaded separately via System Settings

## Version

**v0.3.0-beta** - Beta release (Apple Intelligence only)

See [CHANGELOG](https://github.com/harrykeen18/localscribe/releases) for version history.

## Acknowledgments

- [Whisper.cpp](https://github.com/ggerganov/whisper.cpp) - Local speech-to-text engine
- [FluidAudio](https://github.com/FluidInference/FluidAudio) - On-device speaker diarization (Sortformer)
- Apple Intelligence (Foundation Models) - On-device summarization

---

**Made with privacy in mind.** All processing happens on your device.
