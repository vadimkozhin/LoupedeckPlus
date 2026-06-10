#!/bin/bash
set -e

# Loupedeck macOS App Builder and Packager
# Compiles the Loupedeck daemon, generates icons, wraps it in an App Bundle,
# and supports custom architectures, installation, and release zipping.

echo "=================================================="
echo "    Loupedeck macOS App Compiler & Packager       "
echo "=================================================="

# Default settings
ARCH="arm64"
INSTALL=true
RELEASE=false
CLEAN=false
HAS_ARGS=false
INSTALL_EXPLICIT=false

# Print usage
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --arch <arm64|x86_64>   Build for a specific architecture (default: arm64)"
    echo "  --install               Install the compiled app into the /Applications directory"
    echo "  --release               Zip the app bundle and place it in the 'release' directory"
    echo "  --clean                 Clean all build artifacts (can be combined with other options)"
    echo "  -h, --help              Show this help message"
    exit 1
}

# Parse options
while [[ "$#" -gt 0 ]]; do
    HAS_ARGS=true
    case $1 in
        --arch)
            ARCH="$2"
            if [ "$ARCH" != "arm64" ] && [ "$ARCH" != "x86_64" ]; then
                echo "Error: Invalid architecture '$ARCH'. Supported values are 'arm64' and 'x86_64'."
                exit 1
            fi
            shift 2
            ;;
        --install)
            INSTALL_EXPLICIT=true
            shift
            ;;
        --release)
            RELEASE=true
            shift
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Resolve default installation behavior
if [ "$HAS_ARGS" = false ]; then
    # Default: arm64 build and install
    ARCH="arm64"
    INSTALL=true
    RELEASE=false
else
    # If arguments are passed:
    # 1. Install if explicitly requested
    # 2. If --release is requested and --install is not explicitly requested, do not install
    # 3. Otherwise, if only --arch is passed, default to install
    # 4. If --clean is passed alone, do not install or build
    if [ "$INSTALL_EXPLICIT" = true ]; then
        INSTALL=true
    elif [ "$RELEASE" = true ]; then
        INSTALL=false
    elif [ "$CLEAN" = true ] && [ "$INSTALL_EXPLICIT" = false ] && [ "$RELEASE" = false ]; then
        INSTALL=false
    else
        INSTALL=true
    fi
fi

echo "Configuration:"
echo "  Architecture: $ARCH"
echo "  Install App:  $INSTALL"
echo "  Release Zip:  $RELEASE"
echo "  Clean First:  $CLEAN"
echo "--------------------------------------------------"

# 0. Clean if requested
if [ "$CLEAN" = true ]; then
    echo "[Step 0] Cleaning build artifacts..."
    swift package clean 2>/dev/null || true
    rm -rf .build
    rm -rf release
    rm -rf LoupedeckPlus.app
    rm -rf AppIcon.iconset
    rm -f AppIcon.icns
    echo "Clean complete."
    
    # Exit if no build or install actions were requested
    if [ "$INSTALL" = false ] && [ "$RELEASE" = false ]; then
        exit 0
    fi
fi

# 1. Stop any currently running instance of LoupedeckPlus (only if we plan to install/replace)
if [ "$INSTALL" = true ]; then
    echo "[Step 1] Stopping any running instance of LoupedeckPlus..."
    killall LoupedeckPlus 2>/dev/null || true
fi

# 2. Compile the Swift package for specified architecture
echo "[Step 2] Compiling Swift package for architecture $ARCH..."
swift build -c release --product LoupedeckPlusDaemon --arch $ARCH

# 3. Prepare the AppIcon.icns from icons/AppIcon.png
echo "[Step 3] Generating AppIcon.icns from icons/AppIcon.png..."
ICON_SRC="icons/AppIcon.png"
if [ ! -f "$ICON_SRC" ]; then
    echo "Error: $ICON_SRC not found!"
    exit 1
fi

rm -rf AppIcon.iconset
mkdir -p AppIcon.iconset
sync

sips -s format png -z 16 16     "$ICON_SRC" --out AppIcon.iconset/icon_16x16.png > /dev/null
sips -s format png -z 32 32     "$ICON_SRC" --out AppIcon.iconset/icon_16x16@2x.png > /dev/null
sips -s format png -z 32 32     "$ICON_SRC" --out AppIcon.iconset/icon_32x32.png > /dev/null
sips -s format png -z 64 64     "$ICON_SRC" --out AppIcon.iconset/icon_32x32@2x.png > /dev/null
sips -s format png -z 128 128   "$ICON_SRC" --out AppIcon.iconset/icon_128x128.png > /dev/null
sips -s format png -z 256 256   "$ICON_SRC" --out AppIcon.iconset/icon_128x128@2x.png > /dev/null
sips -s format png -z 256 256   "$ICON_SRC" --out AppIcon.iconset/icon_256x256.png > /dev/null
sips -s format png -z 512 512   "$ICON_SRC" --out AppIcon.iconset/icon_256x256@2x.png > /dev/null
sips -s format png -z 512 512   "$ICON_SRC" --out AppIcon.iconset/icon_512x512.png > /dev/null
sips -s format png -z 1024 1024 "$ICON_SRC" --out AppIcon.iconset/icon_512x512@2x.png > /dev/null

iconutil -c icns AppIcon.iconset
rm -rf AppIcon.iconset

# 4. Create App Bundle Directory Structure
echo "[Step 4] Assembling LoupedeckPlus.app bundle..."
APP_DIR="LoupedeckPlus.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy binary matching the target architecture (renaming to LoupedeckPlus)
BINARY_PATH=".build/${ARCH}-apple-macosx/release/LoupedeckPlusDaemon"
if [ ! -f "$BINARY_PATH" ]; then
    echo "Error: Compiled binary not found at $BINARY_PATH"
    exit 1
fi
cp "$BINARY_PATH" "$APP_DIR/Contents/MacOS/LoupedeckPlus"

# Copy resources
cp AppIcon.icns "$APP_DIR/Contents/Resources/"
rm AppIcon.icns

# Copy custom status icons
if [ -f "icons/StatusIcon.png" ]; then
    cp icons/StatusIcon.png "$APP_DIR/Contents/Resources/"
fi
if [ -f "icons/StatusIcon@2x.png" ]; then
    cp icons/StatusIcon@2x.png "$APP_DIR/Contents/Resources/"
fi

# Copy configs folder, UI assets, and scripts directory
if [ -d "configs" ]; then
    cp -R configs "$APP_DIR/Contents/Resources/"
fi
if [ -d "resources/ui" ]; then
    cp -R resources/ui "$APP_DIR/Contents/Resources/"
fi
if [ -d "scripts" ]; then
    cp -R scripts "$APP_DIR/Contents/Resources/"
fi
if [ -d "plugins" ]; then
    cp -R plugins "$APP_DIR/Contents/Resources/"
fi

# Create Info.plist
cat << 'EOF' > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>LoupedeckPlus</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.loupedeck.plus</string>
    <key>CFBundleName</key>
    <string>LoupedeckPlus</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSUIElement</key>
    <string>1</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>LoupedeckPlus needs permission to control Capture One and other applications via AppleScript.</string>
</dict>
</plist>
EOF

# 5. Handle Release packaging (Zipping)
if [ "$RELEASE" = true ]; then
    echo "[Step 5] Extracting version and zipping app for release..."
    VERSION=$(grep 'appVersion =' Sources/LoupedeckPlusDaemon/Config.swift | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$VERSION" ]; then
        VERSION="unknown"
    fi
    
    mkdir -p release
    ZIP_NAME="release/LoupedeckPlus_${ARCH}_${VERSION}.zip"
    rm -f "$ZIP_NAME"
    zip -q -r "$ZIP_NAME" "$APP_DIR"
    echo "  Success! Zipped app bundle created at: $ZIP_NAME"
fi

# 6. Handle Installation
if [ "$INSTALL" = true ]; then
    echo "[Step 6] Deploying LoupedeckPlus.app to /Applications..."
    DEST_APP="/Applications/LoupedeckPlus.app"
    rm -rf "$DEST_APP"
    cp -R "$APP_DIR" "$DEST_APP"
    
    echo "[Step 7] Launching LoupedeckPlus..."
    open "$DEST_APP"
    
    echo "=================================================="
    echo "    Success! LoupedeckPlus app is now running and "
    echo "    installed at: /Applications/LoupedeckPlus.app"
    echo "=================================================="
else
    echo "=================================================="
    echo "    Build complete. App bundle generated locally."
    echo "=================================================="
fi

# Cleanup local app folder
rm -rf "$APP_DIR"
