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
#   ./release_rxswift_binaries.sh 6.10.0
#
# Prerequisites:
#   - gh CLI installed and authenticated  (brew install gh && gh auth login)
#   - Xcode command-line tools            (xcode-select --install)
#   - curl, ditto (both ship with macOS)
# =============================================================================


# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────

HOSTING_REPO="pishija/RxSwiftBinaries"

# Frameworks to extract and publish.
# RxCocoaRuntime is required — internal dependency of RxCocoa, must be its
# own binaryTarget for SPM to link correctly.
FRAMEWORKS=(
  "RxSwift"
  "RxCocoa"
  "RxCocoaRuntime"
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
  echo "Example: $(basename "$0") 6.10.0"
  exit 1
}

[[ $# -ne 1 ]] && usage

RXSWIFT_VERSION="$1"

if ! [[ "$RXSWIFT_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "Error: '$RXSWIFT_VERSION' does not look like a valid version (e.g. 6.10.0)."
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
# CHECKSUM HELPERS
# Stored as files to avoid bash 3.2 associative array limitation
# ──────────────────────────────────────────────────────────────────────────────

PUBLISHED_FRAMEWORKS=()

checksum_for() { cat "${WORK_DIR}/checksums/${1}"; }
save_checksum() { mkdir -p "${WORK_DIR}/checksums"; printf '%s' "$2" > "${WORK_DIR}/checksums/${1}"; }


# ──────────────────────────────────────────────────────────────────────────────
# STEP 0 — Preflight checks
# ──────────────────────────────────────────────────────────────────────────────

check_prerequisites() {
  step "Preflight checks"

  local missing=0
  for tool in gh xcrun curl ditto; do
    if command -v "$tool" &>/dev/null; then
      success "'$tool' found at $(command -v "$tool")"
    else
      warn "'$tool' is not installed."
      missing=1
    fi
  done
  if [[ $missing -eq 1 ]]; then
    error "Install missing tools and retry."
  fi

  info "Swift toolchain: $(xcrun swift --version 2>&1 | head -1)"

  info "Verifying gh authentication..."
  gh auth status 2>&1 | grep -q "Logged in" \
    || error "gh CLI is not authenticated. Run: gh auth login"

  info "Verifying access to '${HOSTING_REPO}'..."
  gh repo view "$HOSTING_REPO" --json name --jq '.name' &>/dev/null \
    || error "Cannot access '${HOSTING_REPO}'."

  success "All checks passed."
}


# ──────────────────────────────────────────────────────────────────────────────
# STEP 1 — Download the official RxSwift release bundle
# ──────────────────────────────────────────────────────────────────────────────

download_bundle() {
  step "Downloading RxSwift ${RXSWIFT_VERSION} bundle"

  local bundle_url="https://github.com/ReactiveX/RxSwift/releases/download/${RXSWIFT_VERSION}/RxSwift.xcframework.zip"
  local bundle_zip="${WORK_DIR}/RxSwift-bundle.zip"

  mkdir -p "$WORK_DIR"

  info "Checking release exists..."
  local http_status
  http_status=$(curl -o /dev/null -sIL -w "%{http_code}" "$bundle_url")
  [[ "$http_status" == "200" ]] \
    || error "No bundle found for RxSwift ${RXSWIFT_VERSION} (HTTP ${http_status}).\nCheck: https://github.com/ReactiveX/RxSwift/releases"

  info "Downloading..."
  curl -L --progress-bar -o "$bundle_zip" "$bundle_url"

  local size
  size=$(du -sh "$bundle_zip" | cut -f1)
  success "Downloaded (${size}) → ${bundle_zip}"
}


# ──────────────────────────────────────────────────────────────────────────────
# STEP 2 — Extract the bundle
# ──────────────────────────────────────────────────────────────────────────────

extract_bundle() {
  step "Extracting bundle"

  local bundle_zip="${WORK_DIR}/RxSwift-bundle.zip"
  local extract_dir="${WORK_DIR}/extracted"

  mkdir -p "$extract_dir"

  # ditto preserves macOS metadata and symlinks correctly.
  # unzip silently drops symlinks, producing empty directories for frameworks
  # like RxCocoa and RxRelay that use symlinks for some binary slices.
  ditto -x -k "$bundle_zip" "$extract_dir"

  local found
  found=$(find "$extract_dir" -name "*.xcframework" -maxdepth 4 | sort)
  if [[ -z "$found" ]]; then
    error "No .xcframework directories found after extraction."
  fi

  info "Found xcframeworks:"
  while IFS= read -r fw; do
    local fw_size
    fw_size=$(du -sh "$fw" | cut -f1)
    echo "    $(basename "$fw")  (${fw_size})"
  done <<< "$found"

  success "Extraction complete."
}


# ──────────────────────────────────────────────────────────────────────────────
# STEP 3 — Create individual zips & compute SPM checksums
# ──────────────────────────────────────────────────────────────────────────────

package_frameworks() {
  step "Packaging frameworks individually"

  local extract_dir="${WORK_DIR}/extracted"
  local resolved_dir="${WORK_DIR}/resolved"
  local zips_dir="${WORK_DIR}/zips"
  mkdir -p "$zips_dir" "$resolved_dir"

  for fw_name in "${FRAMEWORKS[@]}"; do
    local fw_path
    fw_path=$(find "$extract_dir" -name "${fw_name}.xcframework" -maxdepth 5 | head -1)

    if [[ -z "$fw_path" ]]; then
      warn "${fw_name}.xcframework not found in bundle — skipping."
      continue
    fi

    # Use cp -RL to produce a fully symlink-resolved copy before zipping.
    # Some xcframework slices (e.g. macos, maccatalyst) use symlinks as the
    # actual binary file. ditto -L only resolves top-level symlinks, not
    # symlinks that ARE the binary. cp -RL recurses into all directories and
    # replaces every symlink with the real file it points to, at any depth.
    info "Resolving symlinks for ${fw_name}..."
    local resolved_fw="${resolved_dir}/${fw_name}.xcframework"
    rm -rf "$resolved_fw"
    cp -RL "$fw_path" "$resolved_fw"

    # Verify the resolved copy has real content
    local resolved_size_bytes
    resolved_size_bytes=$(find "$resolved_fw" -type f | xargs wc -c 2>/dev/null | tail -1 | awk '{print $1}')
    if [[ "$resolved_size_bytes" -lt 100000 ]]; then
      error "${fw_name}.xcframework resolved copy is too small (${resolved_size_bytes} bytes).\ncp -RL may have failed to resolve symlinks."
    fi
    info "${fw_name} resolved size: $(du -sh "$resolved_fw" | cut -f1)"

    local zip_path="${zips_dir}/${fw_name}.xcframework.zip"

    info "Zipping ${fw_name}.xcframework..."
    # Zip from resolved_dir so the archive root is exactly XYZ.xcframework/
    (cd "$resolved_dir" && ditto -c -k --sequesterRsrc --keepParent "${fw_name}.xcframework" "$zip_path")

    # Sanity check zip size
    local zip_bytes
    zip_bytes=$(wc -c < "$zip_path")
    if [[ "$zip_bytes" -lt 1000000 ]]; then
      error "${fw_name}.xcframework.zip is too small ($(du -sh "$zip_path" | cut -f1)).\nCheck: unzip -l ${zip_path}"
    fi

    info "Computing checksum for ${fw_name}..."
    local checksum
    checksum=$(xcrun swift package compute-checksum "$zip_path")
    save_checksum "$fw_name" "$checksum"
    PUBLISHED_FRAMEWORKS+=("$fw_name")

    success "${fw_name}  →  ${checksum}"
  done

  if [[ ${#PUBLISHED_FRAMEWORKS[@]} -eq 0 ]]; then
    error "No frameworks were packaged successfully."
  fi
}


# ──────────────────────────────────────────────────────────────────────────────
# STEP 4 — Create GitHub release & upload assets
# ──────────────────────────────────────────────────────────────────────────────

RELEASE_TAG=""

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

  # Verify all zips exist before touching GitHub
  local zip_files=()
  for fw_name in "${PUBLISHED_FRAMEWORKS[@]}"; do
    local zip_path="${zips_dir}/${fw_name}.xcframework.zip"
    if [[ ! -f "$zip_path" ]]; then
      error "Expected zip not found: ${zip_path}"
    fi
    zip_files+=("$zip_path")
  done

  # Create release and upload all assets in one atomic command
  info "Creating release '${RELEASE_TAG}' and uploading ${#zip_files[@]} assets..."
  gh release create "$RELEASE_TAG" \
    --repo "$HOSTING_REPO" \
    --title "$release_title" \
    --notes "$notes" \
    "${zip_files[@]}"

  success "Release live at: https://github.com/${HOSTING_REPO}/releases/tag/${RELEASE_TAG}"
}


# ──────────────────────────────────────────────────────────────────────────────
# STEP 5 — Let SPM resolve the authoritative checksums
# ──────────────────────────────────────────────────────────────────────────────
# GitHub may serve different bytes than the local file (CDN variance).
# The only guaranteed-correct checksum is the one SPM itself computes.
#
# Strategy:
#   1. Write Package.swift with dummy checksums
#   2. Run swift package resolve — fails and prints the real checksums
#   3. Parse those values from the error output
#   4. Rewrite Package.swift with the correct checksums

resolve_checksums_via_spm() {
  step "Resolving authoritative checksums via SPM"

  info "Writing Package.swift with dummy checksums..."
  generate_package_swift "0000000000000000000000000000000000000000000000000000000000000000"

  xcrun swift package reset > /dev/null 2>&1 || true

  info "Running swift package resolve..."
  local resolve_output
  resolve_output=$(xcrun swift package resolve 2>&1 || true)

  local updated=0
  for fw_name in "${PUBLISHED_FRAMEWORKS[@]}"; do
    local spm_checksum
    spm_checksum=$(echo "$resolve_output" \
      | grep "binary target '${fw_name}'" \
      | grep -oE '\([a-f0-9]{64}\)' \
      | head -1 \
      | tr -d '()')

    if [[ -n "$spm_checksum" ]]; then
      save_checksum "$fw_name" "$spm_checksum"
      success "${fw_name} → ${spm_checksum}"
      updated=$((updated + 1))
    else
      warn "No SPM checksum found for ${fw_name}."
    fi
  done

  xcrun swift package reset > /dev/null 2>&1 || true
  rm -f Package.resolved

  if [[ $updated -eq 0 ]]; then
    info "Raw SPM output:"
    echo "$resolve_output"
    error "Could not extract any checksums from SPM output."
  fi

  success "Updated ${updated} checksum(s) from SPM."
}


# ──────────────────────────────────────────────────────────────────────────────
# STEP 6 — Generate Package.swift
# ──────────────────────────────────────────────────────────────────────────────

generate_package_swift() {
  local checksum_override="${1:-}"

  [[ -z "$checksum_override" ]] && step "Generating Package.swift"

  local output_file="$(pwd)/Package.swift"
  local base_url="https://github.com/${HOSTING_REPO}/releases/download/${RELEASE_TAG}"

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

    # Products — RxCocoaRuntime excluded (internal, not for direct import)
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
        echo "        .library(name: \"${fw_name}\", targets: [\"${fw_name}\"]),  "
      fi
    done
    echo "    ],"

    # Binary targets
    echo "    targets: ["
    local last_fw="${PUBLISHED_FRAMEWORKS[${#PUBLISHED_FRAMEWORKS[@]}-1]}"
    for fw_name in "${PUBLISHED_FRAMEWORKS[@]}"; do
      local cs
      if [[ -n "$checksum_override" ]]; then
        cs="$checksum_override"
      else
        cs="$(checksum_for "$fw_name")"
      fi
      echo "        .binaryTarget("
      echo "            name: \"${fw_name}\","
      echo "            url: \"${base_url}/${fw_name}.xcframework.zip\","
      echo "            checksum: \"${cs}\""
      if [[ "$fw_name" == "$last_fw" ]]; then
        echo "        )"
      else
        echo "        ),"
      fi
    done
    echo "    ]"
    echo ")"
  } > "$output_file"

  [[ -z "$checksum_override" ]] && success "Package.swift written to: ${output_file}"
}


# ──────────────────────────────────────────────────────────────────────────────
# STEP 7 — Validate Package.swift
# ──────────────────────────────────────────────────────────────────────────────

validate_package_swift() {
  step "Validating Package.swift"

  info "Checking manifest syntax (swift package dump-package)..."
  if ! xcrun swift package dump-package > /dev/null 2>&1; then
    error "Package.swift failed to parse:\n$(xcrun swift package dump-package 2>&1)"
  fi
  success "Manifest syntax OK."

  info "Resolving package graph (swift package describe)..."
  local describe_output
  if ! describe_output=$(xcrun swift package describe 2>&1); then
    error "Package.swift failed to resolve:\n${describe_output}"
  fi
  success "Package graph resolved OK."

  xcrun swift package reset > /dev/null 2>&1 || true
  rm -f Package.resolved
}


# ──────────────────────────────────────────────────────────────────────────────
# STEP 8 — Commit & push Package.swift to the hosting repo
# ──────────────────────────────────────────────────────────────────────────────

commit_package_swift() {
  step "Committing Package.swift to ${HOSTING_REPO}"

  if ! git -C "$(pwd)" rev-parse --git-dir &>/dev/null; then
    warn "Not inside a git repository — skipping auto-commit."
    warn "Please commit and push Package.swift manually."
    return
  fi

  local remote_url
  remote_url=$(git -C "$(pwd)" remote get-url origin 2>/dev/null || true)
  if [[ "$remote_url" != *"${HOSTING_REPO}"* ]]; then
    warn "Remote origin (${remote_url}) does not match ${HOSTING_REPO}."
    warn "Please commit and push Package.swift manually."
    return
  fi

  git -C "$(pwd)" add Package.swift

  if git -C "$(pwd)" diff --cached --quiet; then
    info "Package.swift unchanged — nothing to commit."
    return
  fi

  git -C "$(pwd)" commit -m "Add Package.swift for RxSwift ${RXSWIFT_VERSION} binaries"
  git -C "$(pwd)" push origin HEAD

  success "Package.swift committed and pushed."
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
  echo -e "  1. Package.swift has been committed and pushed automatically."
  echo -e "     (If skipped, commit it manually and push.)"
  echo -e "  2. Consumers add your package in Xcode using:"
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
  resolve_checksums_via_spm
  generate_package_swift
  validate_package_swift
  commit_package_swift
  print_summary
}

main "$@"