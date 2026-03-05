#!/bin/bash
# Test script for tools bootstrap system

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TOOLS_DIR="$SCRIPT_DIR"

source "$TOOLS_DIR/lib/utils.sh"

echo "=========================================="
echo "Tools Bootstrap System - Test Suite"
echo "=========================================="
echo

# Test 1: Check library files exist
echo "Test 1: Checking library files..."
passed=0
total=0

for lib in utils.sh downloader.sh builder.sh; do
  total=$((total + 1))
  if [[ -f "$TOOLS_DIR/lib/$lib" ]]; then
    echo "  ✓ $lib exists"
    passed=$((passed + 1))
  else
    echo "  ✗ $lib missing"
  fi
done

echo "Result: $passed/$total tests passed"
echo

# Test 2: Check manifest.yaml
echo "Test 2: Checking manifest.yaml..."
total=0
passed=0

total=$((total + 1))
if [[ -f "$TOOLS_DIR/manifest.yaml" ]]; then
  echo "  ✓ manifest.yaml exists"
  passed=$((passed + 1))
else
  echo "  ✗ manifest.yaml missing"
fi

total=$((total + 1))
if command_exists python3; then
  echo "  ✓ python3 available"
  passed=$((passed + 1))
else
  echo "  ✗ python3 not available"
fi

echo "Result: $passed/$total tests passed"
echo

# Test 3: Check setup script
echo "Test 3: Checking setup script..."
total=0
passed=0

total=$((total + 1))
if [[ -x "$TOOLS_DIR/setup.sh" ]]; then
  echo "  ✓ setup.sh is executable"
  passed=$((passed + 1))
else
  echo "  ✗ setup.sh is not executable"
fi

echo "Result: $passed/$total tests passed"
echo

# Test 4: List tools from manifest
echo "Test 4: Reading tools from manifest..."
if [[ -f "$TOOLS_DIR/manifest.yaml" ]]; then
  tools=$(get_tool_list "$TOOLS_DIR/manifest.yaml")
  
  if [[ -n "$tools" ]]; then
    echo "  Found tools:"
    echo "$tools" | while read -r tool; do
      echo "    - $tool"
    done
  else
    echo "  ✗ No tools found in manifest"
  fi
else
  echo "  ✗ Cannot test: manifest.yaml missing"
fi
echo

# Test 5: Check directories
echo "Test 5: Checking directory structure..."
total=0
passed=0

for dir in lib bin cache; do
  total=$((total + 1))
  if [[ -d "$TOOLS_DIR/$dir" ]]; then
    echo "  ✓ $dir/ exists"
    passed=$((passed + 1))
  else
    echo "  ✗ $dir/ missing"
  fi
done

echo "Result: $passed/$total tests passed"
echo

echo "=========================================="
echo "Test Suite Complete"
echo "=========================================="
echo
echo "Next steps:"
echo "1. Run './setup.sh' to install tools"
echo "2. Run './setup.sh --check-only' to verify"
echo "3. Run './setup.sh --list' to see all tools"
echo