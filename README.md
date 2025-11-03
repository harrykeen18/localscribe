# LocalScribe (Experimental)

**⚠️ EXPERIMENTAL RELEASE - Includes Ollama support with network features**

LocalScribe captures audio from meeting apps (Zoom, Google Meet, etc.), transcribes locally with Whisper.cpp, and summarizes using Apple Intelligence OR Ollama (local/remote).

**For maximum privacy, use the [stable branch](https://github.com/harrykeen18/localscribe/tree/stable) (Apple Intelligence only, zero network access).**

## Features

- **System Audio + Microphone Capture** - Records both sides via ScreenCaptureKit
- **Local Transcription** - Whisper.cpp base.en model (bundled, offline)
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

- **macOS 15.1 (Sequoia)** or later
- **Apple Silicon** (M1, M2, M3, M4, or newer)
- **Apple Intelligence** (for Apple Intelligence option)
- **Ollama** (for Ollama options) - [Install from ollama.com](https://ollama.com)
- ~500MB disk space

## Installation

1. Download `LocalScribe-v0.2.2-experimental.zip` from [GitHub Releases](https://github.com/harrykeen18/localscribe/releases)
2. **Verify checksum**:
   ```bash
   shasum -a 256 -c LocalScribe-v0.2.2-experimental.zip.sha256
   ```
3. Extract and move `LocalScribe.app` to `/Applications`
4. **First launch**: Right-click → Open (unsigned build)
5. Grant **Microphone** and **Screen Recording** permissions

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

Email: **harrykeen18@gmail.com** with subject "Security: [Brief Description]"

Include:
- Detailed description and steps to reproduce
- Potential impact
- Your contact info

### Security Measures

- **Encryption**: AES-256-GCM for all transcripts
- **Keychain**: Keys protected by login password/Touch ID
- **Input Validation**: File paths sanitized
- **Sandboxing**: Relies on macOS App Sandbox

### Known Limitations (Experimental)

- ⚠️ **Unsigned build**: Not signed by Apple Developer ID
- ⚠️ **Not notarized**: Not submitted to Apple
- ⚠️ **Network access enabled**: Required for Ollama, creates attack surface
- ⚠️ **Ollama remote NOT private**: Transcript sent over network

## Building from Source

1. Clone the repository:
   ```bash
   git clone https://github.com/harrykeen18/localscribe.git
   cd localscribe
   git checkout experimental
   ```

2. **Download Whisper model files**:
   - Download from the [latest release](https://github.com/harrykeen18/localscribe/releases/latest)
   - Extract `Resources/whisper` and `Resources/base.en.bin` from the release .zip
   - Place in `Resources/` directory

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

**v0.2.2-experimental** - Experimental release with Ollama support

**For maximum privacy, use the [stable release](https://github.com/harrykeen18/localscribe/releases/tag/v0.2.2-beta) instead.**

## Acknowledgments

- [Whisper.cpp](https://github.com/ggerganov/whisper.cpp) - Local speech-to-text
- Apple Intelligence - On-device summarization
- [Ollama](https://ollama.com) - Local/remote LLM support

---

**Privacy note**: This experimental version includes network features. Use stable branch for zero network access.
