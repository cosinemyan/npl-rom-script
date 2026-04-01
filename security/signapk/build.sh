#!/bin/bash
# Build signapk from UN1CA's fork: https://github.com/UN1CA/external_signapk
# Requires: JDK 17+, git, gradle (or ./gradlew)
#
# Usage: ./security/signapk/build.sh
# Output: security/signapk/signapk.jar + security/signapk/signapk wrapper script

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="/tmp/rom-builder-signapk-build"
JAR_OUTPUT="$SCRIPT_DIR/signapk.jar"
WRAPPER_OUTPUT="$SCRIPT_DIR/signapk"

# Check Java version
java_ver=$(java -version 2>&1 | head -1 | grep -oE '[0-9]+' | head -1)
if [[ "$java_ver" -lt 17 ]] 2>/dev/null; then
  echo "ERROR: JDK 17+ required (found: $(java -version 2>&1 | head -1))"
  echo "Install JDK 17 and rerun this script."
  exit 1
fi

echo "Building signapk from UN1CA/external_signapk..."

# Clone if needed
if [[ ! -d "$BUILD_DIR" ]]; then
  git clone --depth 1 https://github.com/UN1CA/external_signapk.git "$BUILD_DIR"
fi

cd "$BUILD_DIR"

# Build fat JAR with Gradle
./gradlew :signapk:shadowJar 2>&1 || {
  echo "ERROR: Gradle build failed"
  exit 1
}

# Copy the built JAR
local_jar="$BUILD_DIR/signapk/build/libs/signapk-all.jar"
if [[ ! -f "$local_jar" ]]; then
  echo "ERROR: Built JAR not found at $local_jar"
  exit 1
fi

cp "$local_jar" "$JAR_OUTPUT"
echo "Built: $JAR_OUTPUT ($(du -h "$JAR_OUTPUT" | awk '{print $1}'))"

# Create wrapper script
cat > "$WRAPPER_OUTPUT" << 'EOF'
#!/bin/bash
exec java -jar "$(dirname "$0")/signapk.jar" "$@"
EOF
chmod +x "$WRAPPER_OUTPUT"
echo "Created wrapper: $WRAPPER_OUTPUT"

# Cleanup
rm -rf "$BUILD_DIR"

echo "signapk built successfully!"
echo "Add to PATH: export PATH=\"$SCRIPT_DIR:\$PATH\""
