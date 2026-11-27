#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "🔨 Building static whisper executable for macOS app bundling"
echo ""

# Check for cmake
if ! command -v cmake &> /dev/null; then
    echo "❌ cmake not found. Installing with Homebrew..."
    brew install cmake
fi

# Create temp directory for build
BUILD_DIR=$(mktemp -d)
echo "📁 Working in: $BUILD_DIR"
cd "$BUILD_DIR"

# Clone whisper.cpp
echo "📥 Cloning whisper.cpp..."
git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git
cd whisper.cpp

# Build with static linking
echo "🔧 Building whisper with static linking..."
cmake -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON \
  -DWHISPER_METAL=ON \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0

echo "⚙️  Compiling (this may take a few minutes)..."
cmake --build build --config Release -j$(sysctl -n hw.ncpu)

# Find the actual whisper CLI executable
echo "🔍 Looking for whisper CLI executable..."
WHISPER_BIN=""

# Check possible locations (newer versions use whisper-cli)
if [ -f "build/bin/whisper-cli" ]; then
    WHISPER_BIN="build/bin/whisper-cli"
    echo "✅ Found at: build/bin/whisper-cli"
elif [ -f "build/bin/main" ]; then
    WHISPER_BIN="build/bin/main"
    echo "✅ Found at: build/bin/main"
elif [ -f "build/examples/main/main" ]; then
    WHISPER_BIN="build/examples/main/main"
    echo "✅ Found at: build/examples/main/main"
else
    echo "❌ Build failed - executable not found"
    echo ""
    echo "Available files in build/bin/:"
    ls -la build/bin/ 2>/dev/null || echo "  Directory not found"
    echo ""
    echo "Available files in build/examples/:"
    find build/examples -name "main" -o -name "*whisper*" 2>/dev/null || echo "  No matches found"
    exit 1
fi

# Verify it's actually a working binary and not the deprecation wrapper
echo "🧪 Testing executable..."
if "$WHISPER_BIN" --help 2>&1 | grep -qi "usage:"; then
    echo "✅ Executable test passed - shows usage info"
elif "$WHISPER_BIN" --help 2>&1 | grep -q "deprecated"; then
    echo "❌ ERROR: This is the deprecated wrapper, not the actual CLI"
    exit 1
else
    echo "⚠️  Warning: Unexpected output from --help, but continuing..."
fi

echo ""
echo "✅ Build complete! Checking dependencies..."
echo ""
otool -L "$WHISPER_BIN"
echo ""

# Check for unwanted dynamic libraries
if otool -L "$WHISPER_BIN" | grep -q "libwhisper\|libggml"; then
    echo "⚠️  WARNING: Executable still has whisper/ggml dynamic library dependencies!"
    echo "This may not work when bundled in the app."
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    echo "✅ No whisper/ggml dynamic library dependencies found - looks good!"
fi

# Copy to Resources
PROJECT_DIR="$SCRIPT_DIR"
RESOURCES_DIR="$PROJECT_DIR/Resources"

echo ""
echo "📋 Copying to: $RESOURCES_DIR/whisper"
cp "$WHISPER_BIN" "$RESOURCES_DIR/whisper"
chmod +x "$RESOURCES_DIR/whisper"

# Sign with Hardened Runtime and sandbox inheritance so the app can be notarized.
# Ad-hoc is enough here: Xcode re-signs it with the release identity on export,
# keeping these options and entitlements.
echo ""
echo "🔏 Signing whisper with Hardened Runtime..."
ENTITLEMENTS_FILE="$(mktemp)"
cat > "$ENTITLEMENTS_FILE" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.inherit</key>
	<true/>
</dict>
</plist>
PLIST
codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS_FILE" "$RESOURCES_DIR/whisper"
rm -f "$ENTITLEMENTS_FILE"

# Verify the copied file
echo ""
echo "🔍 Verifying copied executable..."
otool -L "$RESOURCES_DIR/whisper"

echo ""
echo "✅ Done! Whisper executable updated successfully."
echo "📦 File size: $(du -h "$RESOURCES_DIR/whisper" | cut -f1)"
echo ""
echo "🧹 Cleaning up build directory: $BUILD_DIR"
rm -rf "$BUILD_DIR"
