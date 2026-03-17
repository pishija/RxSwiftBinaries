#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# RxSwift Binary Release Script
# -----------------------------------------------------------------------------
# Downloads the official RxSwift release, unpacks it, creates individual
# .xcframework zips, computes SPM checksums, creates a GitHub release on your
# hosting repo, uploads the assets, and generates a ready-to-use Package.swift.
#
# Usage:
#   ./release_rxswift_binaries.sh <rxswift-version>
#   ./release_rxswift_binaries.sh 6.10.2
#
# Prerequisites:
#   - gh CLI installed and authenticated  (brew install gh && gh auth login)
#   - Xcode command-line tools            (xcode-select --install)
#   - curl, unzip, zip (all ship with macOS)
# =============================================================================


# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — set HOSTING_REPO before running
# ──────────────────────────────────────────────────────────────────────────────

# Your GitHub hosting repo  e.g. "my-org/rxswift-binaries"
HOSTING_REPO="pishija/RxSwiftBinaries"

# Frameworks to extract and publish.
# RxCocoaRuntime is added automatically — it is an internal dependency of
# RxCocoa and must be present as its own binaryTarget for SPM to link correctly.
FRAMEWORKS=(
  "RxSwift"
  "RxCocoa"
  "RxCocoaRuntime"   # required by RxCocoa — do not remove
  "RxRelay"
  "RxTest"
  "RxBlocking"
)

# Minimum platform versions written into Package.swift
IOS_DEPLOYMENT_TARGET="13"
MACOS_DEPLOYMENT_TARGET="10_15"
TVOS_DEPLOYMENT_TARGET="13"
WATCHOS_DEPLOYMENT_TARGET="6"

# Working directory (removed automatically on exit)
WORK_DIR="$(pwd)/.rxswift_release_tmp"


# ──────────────────────────────────────────────────────────────────────────────
# ARGUMENT PARSING
# ──────────────────────────────────────────────────────────────────────────────

usage() {
  echo "Usage: $(basename "$0") <rxswift-version>"
  echo "Example: $(basename "$0") 6.10.2"
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
fi

RXSWIFT_VERSION="$1"

# Basic semver sanity check
if ! [[ "$RXSWIFT_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "Error: '$RXSWIFT_VERSION' does not look like a valid version (e.g. 6.10.2)."
  usage
fi


# ──────────────────────────────────────────────────────────────────────────────
# LOGGING HELPERS
# ──────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}▶ $*${NC}"; }


# ──────────────────────────────────────────────────────────────────────────────
# CLEANUP
# ──────────────────────────────────────────────────────────────────────────────

cleanup() {
  if [[ -d "$WORK_DIR" ]]; then
    info "Cleaning up temporary directory..."
    rm -rf "$WORK_DIR"
  fi
}

trap cleanup EXIT


# ──────────────────────────────────────────────────────────────────────────────
# STEP 0 — Preflight checks
# ──────────────────────────────────────────────────────────────────────────────

check_prerequisites() {
  step "Preflight checks"

  local missing=0
  for tool in gh xcrun curl unzip zip shasum; do
    if command -v "$tool" &>/dev/null; then
      success "'$tool' found at $(command -v "$tool")"
    else
      warn "'$tool' is not installed."
      missing=1
    fi
  done
  [[ $missing -eq 1 ]] && error "Install missing tools and retry."

  if [[ "$HOSTING_REPO" == "YOUR_ORG/YOUR_REPO" ]]; then
    error "Set HOSTING_REPO at the top of this script before running.\nExample: HOSTING_REPO=\"my-org/rxswift-binaries\""
  fi

  info "Verifying gh authentication..."
  gh auth status 2>&1 | grep -q "Logged in" \
    || error "gh CLI is not authenticated. Run: gh auth login"

  info "Verifying access to '${HOSTING_REPO}'..."
  gh repo view "$HOSTING_REPO" --json name --jq '.name' &>/dev/null \
    || error "Cannot access '${HOSTING_REPO}'. Check the repo name and your permissions."

  info "Swift toolchain in use: $(xcrun swift --version 2>&1 | head -1)"
  success "All checks passed." 
}


# ──────────────────────────────────────────────────────────────────────────────
# STEP 1 — Download the official RxSwift release bundle
# ──────────────────────────────────────────────────────────────────────────────

download_bundle() {
  step "Downloading RxSwift ${RXSWIFT_VERSION} bundle"

  # The official release ships a single zip called RxSwift.xcframework.zip
  # which contains ALL xcframeworks bundled together.
  local bundle_url="https://github.com/ReactiveX/RxSwift/releases/download/${RXSWIFT_VERSION}/RxSwift.xcframework.zip"
  local bundle_zip="${WORK_DIR}/RxSwift-bundle.zip"

  mkdir -p "$WORK_DIR"

  info "Checking release exists at GitHub..."
  local http_status
  http_status=$(curl -o /dev/null -sIL -w "%{http_code}" "$bundle_url")
  [[ "$http_status" == "200" ]] \
    || error "No bundle found for RxSwift ${RXSWIFT_VERSION} (HTTP ${http_status}).\nBrowse available releases: https://github.com/ReactiveX/RxSwift/releases"

  info "Downloading from:\n  ${bundle_url}"
  curl -L --progress-bar -o "$bundle_zip" "$bundle_url"

  local size
  size=$(du -sh "$bundle_zip" | cut -f1)
  success "Downloaded bundle (${size}) → ${bundle_zip}"
}


# ──────────────────────────────────────────────────────────────────────────────
# STEP 2 — Extract the bundle
# ──────────────────────────────────────────────────────────────────────────────

extract_bundle() {
  step "Extracting bundle"

  local bundle_zip="${WORK_DIR}/RxSwift-bundle.zip"
  local extract_dir="${WORK_DIR}/extracted"

  mkdir -p "$extract_dir"
  unzip -q "$bundle_zip" -d "$extract_dir"

  local found
  found=$(find "$extract_dir" -name "*.xcframework" -maxdepth 4 | sort)

  if [[ -z "$found" ]]; then
    error "No .xcframework directories found in the zip. The bundle structure may have changed upstream."
  fi

  info "Found xcframeworks in bundle:"
  while IFS= read -r fw; do
    echo "    $(basename "$fw")"
  done <<< "$found"

  success "Extraction complete."
}


# ──────────────────────────────────────────────────────────────────────────────
# STEP 3 — Create individual zips & compute SPM checksums
# ──────────────────────────────────────────────────────────────────────────────

# Populated here, consumed by steps 4 and 5.
# Checksums are stored as individual files under $WORK_DIR/checksums/
# to avoid needing bash 4's associative arrays (macOS ships bash 3.2).
PUBLISHED_FRAMEWORKS=()

checksum_for() { cat "${WORK_DIR}/checksums/${1}"; }
save_checksum() { mkdir -p "${WORK_DIR}/checksums"; echo "$2" > "${WORK_DIR}/checksums/${1}"; }

package_frameworks() {
  step "Packaging frameworks individually"

  local extract_dir="${WORK_DIR}/extracted"
  local zips_dir="${WORK_DIR}/zips"
  mkdir -p "$zips_dir"

  for fw_name in "${FRAMEWORKS[@]}"; do
    local fw_path
    fw_path=$(find "$extract_dir" -name "${fw_name}.xcframework" -maxdepth 5 | head -1)

    if [[ -z "$fw_path" ]]; then
      warn "${fw_name}.xcframework was not found in this release's bundle — skipping."
      continue
    fi

    local zip_path="${zips_dir}/${fw_name}.xcframework.zip"

    info "Zipping ${fw_name}.xcframework..."
    # Zip from the parent dir so the archive root is exactly XYZ.xcframework/
    (cd "$(dirname "$fw_path")" && zip -r -X --quiet "$zip_path" "${fw_name}.xcframework")

    info "Computing SPM checksum for ${fw_name}..."
    local checksum
    # Use xcrun to guarantee the Xcode-bundled swift (5.2+) is used, not any
    # older toolchain on PATH (e.g. a swift-5.0-RELEASE toolchain).
    # compute-checksum is a plain SHA-256; shasum is used as a fallback.
    if xcrun swift package compute-checksum "$zip_path" > /dev/null 2>&1; then
      checksum=$(xcrun swift package compute-checksum "$zip_path")
    else
      warn "xcrun swift package compute-checksum unavailable — falling back to shasum"
      checksum=$(shasum -a 256 "$zip_path" | awk '{print $1}')
    fi

    save_checksum "$fw_name" "$checksum"
    PUBLISHED_FRAMEWORKS+=("$fw_name")

    success "${fw_name}  →  ${checksum}"
  done

  if [[ ${#PUBLISHED_FRAMEWORKS[@]} -eq 0 ]]; then
    error "No frameworks were packaged successfully. Nothing to release."
  fi
}


# ──────────────────────────────────────────────────────────────────────────────
# STEP 4 — Create GitHub release & upload assets
# ──────────────────────────────────────────────────────────────────────────────

RELEASE_TAG=""  # set here, consumed by step 5

create_github_release() {
  step "Creating GitHub release on ${HOSTING_REPO}"

  local zips_dir="${WORK_DIR}/zips"
  RELEASE_TAG="rxswift-${RXSWIFT_VERSION}"
  local release_title="RxSwift ${RXSWIFT_VERSION} — Prebuilt XCFramework Binaries"

  # Handle pre-existing release
  if gh release view "$RELEASE_TAG" --repo "$HOSTING_REPO" &>/dev/null; then
    warn "Release '${RELEASE_TAG}' already exists on ${HOSTING_REPO}."
    read -rp "  Delete and recreate it? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      gh release delete "$RELEASE_TAG" --repo "$HOSTING_REPO" --yes
      # Also remove the remote tag so it can be recreated cleanly
      gh api "repos/${HOSTING_REPO}/git/refs/tags/${RELEASE_TAG}" \
        -X DELETE &>/dev/null || true
      info "Existing release deleted."
    else
      error "Aborting. Remove the existing release manually and rerun."
    fi
  fi

  # Build release notes
  local fw_list=""
  for fw in "${PUBLISHED_FRAMEWORKS[@]}"; do
    fw_list+="- \`${fw}.xcframework\`"$'\n'
  done

  local checksum_list=""
  for fw in "${PUBLISHED_FRAMEWORKS[@]}"; do
    checksum_list+="- **${fw}**: \`$(checksum_for "$fw")\`"$'\n'
  done

  local notes
  notes="## RxSwift ${RXSWIFT_VERSION} — Prebuilt XCFramework Binaries

Individually repackaged from the [official RxSwift ${RXSWIFT_VERSION} release](https://github.com/ReactiveX/RxSwift/releases/tag/${RXSWIFT_VERSION}) for use as SPM \`binaryTarget\`s.

### Included Frameworks
${fw_list}
### SPM Checksums
${checksum_list}
### Usage
Add this repository as a Swift Package in Xcode or your \`Package.swift\`:
\`\`\`
https://github.com/${HOSTING_REPO}
\`\`\`"

  info "Creating release '${RELEASE_TAG}'..."
  gh release create "$RELEASE_TAG" \
    --repo "$HOSTING_REPO" \
    --title "$release_title" \
    --notes "$notes"

  # Upload each zip as a release asset
  for fw_name in "${PUBLISHED_FRAMEWORKS[@]}"; do
    local zip_path="${zips_dir}/${fw_name}.xcframework.zip"
    local size
    size=$(du -sh "$zip_path" | cut -f1)
    info "Uploading ${fw_name}.xcframework.zip (${size})..."
    gh release upload "$RELEASE_TAG" "$zip_path" --repo "$HOSTING_REPO"
    success "Uploaded ${fw_name}.xcframework.zip"
  done

  success "Release live at: https://github.com/${HOSTING_REPO}/releases/tag/${RELEASE_TAG}"
}


# ──────────────────────────────────────────────────────────────────────────────
# STEP 5 — Generate Package.swift
# ──────────────────────────────────────────────────────────────────────────────

generate_package_swift() {
  step "Generating Package.swift"

  local output_file="$(pwd)/Package.swift"
  local base_url="https://github.com/${HOSTING_REPO}/releases/download/${RELEASE_TAG}"

  # Open the file for writing
  {
    echo "// swift-tools-version:5.3"
    echo "// Generated by release_rxswift_binaries.sh"
    echo "// RxSwift ${RXSWIFT_VERSION} — https://github.com/${HOSTING_REPO}"
    echo ""
    echo "import PackageDescription"
    echo ""
    echo "let package = Package("
    echo "    name: \"RxSwift\","
    echo "    platforms: ["
    echo "        .iOS(.v${IOS_DEPLOYMENT_TARGET}),"
    echo "        .macOS(.v${MACOS_DEPLOYMENT_TARGET}),"
    echo "        .tvOS(.v${TVOS_DEPLOYMENT_TARGET}),"
    echo "        .watchOS(.v${WATCHOS_DEPLOYMENT_TARGET})"
    echo "    ],"

    # Products block
    # RxCocoaRuntime is intentionally excluded — it's an internal RxCocoa
    # dependency and should not be imported directly by consumers.
    echo "    products: ["
    local last_public_fw=""
    for fw_name in "${PUBLISHED_FRAMEWORKS[@]}"; do
      [[ "$fw_name" == "RxCocoaRuntime" ]] && continue
      last_public_fw="$fw_name"
    done
    for fw_name in "${PUBLISHED_FRAMEWORKS[@]}"; do
      [[ "$fw_name" == "RxCocoaRuntime" ]] && continue
      if [[ "$fw_name" == "$last_public_fw" ]]; then
        echo "        .library(name: \"${fw_name}\", targets: [\"${fw_name}\"])"
      else
        echo "        .library(name: \"${fw_name}\", targets: [\"${fw_name}\"]) ,"
      fi
    done
    echo "    ],"

    # Targets block
    echo "    targets: ["
    local last_fw="${PUBLISHED_FRAMEWORKS[${#PUBLISHED_FRAMEWORKS[@]}-1]}"
    for fw_name in "${PUBLISHED_FRAMEWORKS[@]}"; do
      echo "        .binaryTarget("
      echo "            name: \"${fw_name}\","
      echo "            url: \"${base_url}/${fw_name}.xcframework.zip\","
      echo "            checksum: \"$(checksum_for "$fw_name")\""
      if [[ "$fw_name" == "$last_fw" ]]; then
        echo "        )"
      else
        echo "        ),"
      fi
    done
    echo "    ]"
    echo ")"
  } > "$output_file"

  success "Package.swift written to: ${output_file}"
}


# ──────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ──────────────────────────────────────────────────────────────────────────────

print_summary() {
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║              ✅  Release complete!               ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${CYAN}RxSwift version:${NC}  ${RXSWIFT_VERSION}"
  echo -e "  ${CYAN}Release:${NC}          https://github.com/${HOSTING_REPO}/releases/tag/${RELEASE_TAG}"
  echo -e "  ${CYAN}Frameworks:${NC}       ${PUBLISHED_FRAMEWORKS[*]}"
  echo ""
  echo -e "  ${CYAN}Checksums:${NC}"
  for fw_name in "${PUBLISHED_FRAMEWORKS[@]}"; do
    printf "    %-20s %s\n" "${fw_name}" "$(checksum_for "$fw_name")"
  done
  echo ""
  echo -e "  ${CYAN}Next steps:${NC}"
  echo -e "  1. Copy ${YELLOW}Package.swift${NC} to the root of your hosting repo."
  echo -e "  2. Commit and push it, then tag the commit ${YELLOW}${RELEASE_TAG}${NC}:"
  echo -e "     ${YELLOW}git tag ${RELEASE_TAG} && git push origin ${RELEASE_TAG}${NC}"
  echo -e "  3. Consumers add your package in Xcode using:"
  echo -e "     ${YELLOW}https://github.com/${HOSTING_REPO}${NC}"
  echo ""
}


# ──────────────────────────────────────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────────────────────────────────────

main() {
  echo ""
  echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}${BOLD}║   RxSwift XCFramework Binary Release Tool   ║${NC}"
  echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
  echo -e "  Target version: ${BOLD}${RXSWIFT_VERSION}${NC}"
  echo -e "  Hosting repo:   ${BOLD}${HOSTING_REPO}${NC}"
  echo ""

  check_prerequisites
  download_bundle
  extract_bundle
  package_frameworks
  create_github_release
  generate_package_swift
  print_summary
}

main "$@"