# LocalScribe (Experimental)

**⚠️ EXPERIMENTAL RELEASE - Includes Ollama support with network features**

LocalScribe captures audio from meeting apps (Zoom, Google Meet, etc.), transcribes locally with Whisper.cpp, and summarizes using Apple Intelligence OR Ollama (local/remote).

**For maximum privacy, use the [stable branch](https://github.com/harrykeen18/localscribe/tree/stable) (Apple Intelligence only, zero network access).**

## Features

- **System Audio + Microphone Capture** - Records both sides via ScreenCaptureKit
- **Local Transcription** - Whisper.cpp large-v3-turbo multilingual model with automatic language detection (bundled, offline)
- **Speaker Diarization** - On-device Sortformer model labels up to 4 speakers
- **Multiple Summarization Options**:
  - ✅ **Apple Intelligence** (on-device, private)
  - ⚠️ **Ollama Local/LAN** (localhost/192.168.x.x, private)
  - ⚠️ **Ollama Remote** (network-based, NOT private)
- **Encrypted Storage** - AES-256-GCM encryption, keys in macOS Keychain

## Privacy Warning

### Apple Intelligence Option (Recommended)
- ✅ 100% on-device processing
- ✅ Zero network access
- ✅ Maximum privacy

### Ollama Local/LAN Option
- ⚠️ Sends transcript to localhost or private network (192.168.x.x, 10.x.x.x)
- ✅ Private if used on your own machine or trusted local network
- ⚠️ Requires Ollama installation

### Ollama Remote Option (Advanced)
- ❌ Sends transcript over network to configured server
- ❌ NOT private unless using encrypted tunnel (Tailscale, VPN) or HTTPS
- ⚠️ Plain HTTP over internet exposes your transcript
- ⚠️ Only use with:
  - Tailscale (100.x.x.x - encrypted tunnel)
  - VPN connections
  - HTTPS endpoints

**Recommendation**: Use Apple Intelligence or Ollama Local on your own machine for privacy.

## Requirements

- **macOS 26 (Tahoe)** or later
- **Apple Silicon** (M1, M2, M3, M4, or newer)
- **Apple Intelligence** (for Apple Intelligence option)
- **Ollama** (for Ollama options) - [Install from ollama.com](https://ollama.com)
- ~1GB disk space

## Installation

1. Download `LocalScribe-v0.3.0-experimental.zip` from [GitHub Releases](https://github.com/harrykeen18/localscribe/releases)
2. **Verify checksum**:
   ```bash
   shasum -a 256 -c LocalScribe-v0.3.0-experimental.zip.sha256
   ```
3. Extract and move `LocalScribe.app` to `/Applications`
4. Open LocalScribe (signed with Developer ID and notarized by Apple)
5. Grant **Microphone** and **Screen Recording** permissions

### Updating from v0.2.x

Replace the old `LocalScribe.app` in `/Applications` with the new one. Your transcripts are kept.

Because this release is the first signed with a Developer ID certificate, macOS treats it as a new app once:

- When asked whether LocalScribe can use its key in your Keychain, click **Always Allow**. This key decrypts your existing transcripts.
- Grant **Microphone** and **Screen Recording** again. If recording still fails, remove the old LocalScribe entry under System Settings → Privacy & Security → Screen & System Audio Recording, then add it again.

If the Keychain prompt is denied, no transcripts are lost: LocalScribe sets the unreadable history aside and restores it on the next launch where the key can be read.

## Ollama Setup (Optional)

If you want to use Ollama instead of Apple Intelligence:

1. **Install Ollama**: Download from [ollama.com](https://ollama.com)
2. **Pull a model**:
   ```bash
   ollama pull qwen2.5
   # or: ollama pull llama3.2
   ```
3. **Configure in LocalScribe**:
   - Open Settings → Summarization Provider
   - Expand "Advanced Options"
   - Choose "Ollama (Local/LAN)" for privacy
   - Set Base URL (default: `http://localhost:11434`)
   - Set Model (e.g., `qwen2.5`)
   - Click "Test Connection"

## Usage

1. Click record button
2. Have your meeting
3. Click stop when finished
4. Wait for transcription and summarization
5. View results

## Privacy & Security

### For Apple Intelligence Option

- ✅ **Zero data collection**: Nothing sent anywhere
- ✅ **On-device processing**: Transcription and summarization local
- ✅ **Encrypted storage**: AES-256-GCM
- ✅ **No network code**: Search codebase—no URLSession for this option

### For Ollama Options

- ⚠️ **Transcript sent to configured server**: Your meeting transcript leaves the app
- ⚠️ **Network security depends on configuration**:
  - Localhost: Private ✅
  - Private network (192.168.x.x): Private on trusted network ✅
  - Tailscale/VPN: Encrypted tunnel ✅
  - Plain HTTP over internet: NOT PRIVATE ❌
- ✅ **Encrypted storage**: Transcripts still encrypted at rest locally
- ⚠️ **NSAllowsArbitraryLoads enabled**: Allows HTTP connections (required for local Ollama)

### Technical Verification

```bash
# Check Info.plist (experimental has NSAllowsArbitraryLoads)
grep "NSAllowsArbitraryLoads" LocalScribe.app/Contents/Info.plist

# Monitor network when using Apple Intelligence (should be zero)
sudo nettop -p $(pgrep -x "LocalScribe")

# Monitor network when using Ollama (will show connections to configured server)
```

### Reporting Vulnerabilities

**DO NOT open public issues for security vulnerabilities.**

Please report security issues via GitHub Security Advisories:
https://github.com/harrykeen18/localscribe/security/advisories/new

Include:
- Detailed description and steps to reproduce
- Potential impact
- Suggested fix (if you have one)

### Security Measures

- **Encryption**: AES-256-GCM for all transcripts
- **Keychain**: Keys protected by login password/Touch ID
- **Input Validation**: File paths sanitized
- **Sandboxing**: Relies on macOS App Sandbox

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

### Known Limitations (Experimental)

- ⚠️ **Network access enabled**: Required for Ollama, creates attack surface
- ⚠️ **Ollama remote NOT private**: Transcript sent over network

## Building from Source

1. Clone the repository:
   ```bash
   git clone https://github.com/harrykeen18/localscribe.git
   cd localscribe
   git checkout experimental
   ```

2. **Get the bundled models and Whisper executable**:
   - Download the release .zip from the [releases page](https://github.com/harrykeen18/localscribe/releases)
   - Copy `whisper`, `base.en.bin`, `ggml-large-v3-turbo-q5_0.bin` and `SortformerNvidiaHigh_v2.1.mlmodelc` from `LocalScribe.app/Contents/Resources/` into a `Resources/` directory in the repository
   - Or build the Whisper executable yourself with `./build-whisper.sh`

3. Open in Xcode:
   ```bash
   open transcribe-offline.xcodeproj
   ```

4. Build: Product → Build (⌘B)

5. Run: Product → Run (⌘R)

## Bug Reports

This is experimental software. Report issues via [GitHub Issues](https://github.com/harrykeen18/localscribe/issues).

**Export diagnostics**: Settings → Diagnostics → Copy to Clipboard
(Diagnostics contain NO transcript content—only logs)

## Version

**v0.3.0-experimental** - Experimental release with Ollama support

**For maximum privacy, use the [stable release](https://github.com/harrykeen18/localscribe/releases/tag/v0.3.0-beta) instead.**

## Acknowledgments

- [Whisper.cpp](https://github.com/ggerganov/whisper.cpp) - Local speech-to-text
- [FluidAudio](https://github.com/FluidInference/FluidAudio) - On-device speaker diarization (Sortformer)
- Apple Intelligence - On-device summarization
- [Ollama](https://ollama.com) - Local/remote LLM support

---

**Privacy note**: This experimental version includes network features. Use stable branch for zero network access.
