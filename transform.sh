#!/bin/bash

# SPDX-FileCopyrightText: 2025 Igor Kha.
# SPDX-License-Identifier: MIT.

# DNS Filter Transformation Script
# Converts various DNS filter formats to hosts file format
# Author: Refactored for improved maintainability and pipeline compatibility

set -euo pipefail

# Configuration
SCRIPT_NAME="$(basename "$0")"
readonly OUTPUT_DIR="hosts"
readonly TEMP_DIR_PREFIX="dns_transform"

# Global counters
declare -i g_total_transformed=0
declare -i g_processed_filters=0
declare -i g_failed_downloads=0

# Logging functions
log_info() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] INFO: $*" >&2
}

log_error() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] ERROR: $*" >&2
}

log_warning() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] WARNING: $*" >&2
}

# Usage and validation functions
show_usage() {
    cat << EOF
Usage: $SCRIPT_NAME <filters.json|URL>

Transforms DNS filter files from various formats to hosts file format.

Arguments:
  filters.json    JSON file containing filter definitions (local file or URL)
                  Example: https://adguardteam.github.io/HostlistsRegistry/assets/filters.json

Requirements:
  - jq (JSON processor)
  - curl (for downloading filters)

Output:
  Transformed files are saved to '$OUTPUT_DIR/' directory
EOF
}

validate_dependencies() {
    local -a missing_deps=()

    command -v jq >/dev/null || missing_deps+=("jq")
    command -v curl >/dev/null || missing_deps+=("curl")

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_error "Please install missing tools and try again"
        return 1
    fi
}

# Add function to download JSON file
download_json_file() {
    local -r source="$1"
    local -r temp_dir="$2"

    if [[ "$source" =~ ^https?:// ]]; then
        local -r json_file="$temp_dir/filters.json"
        log_info "Downloading JSON file from: $source"

        if ! download_filter "$source" "$json_file"; then
            log_error "Failed to download JSON file from $source"
            return 1
        fi

        echo "$json_file"
    else
        echo "$source"
    fi
}

validate_json_file() {
    local -r json_file="$1"

    [[ -f "$json_file" ]] || {
        log_error "JSON file '$json_file' not found"
        return 1
    }

    jq empty "$json_file" 2>/dev/null || {
        log_error "Invalid JSON format in '$json_file'"
        return 1
    }

    # Validate required structure
    jq -e '.filters | type == "array"' "$json_file" >/dev/null || {
        log_error "JSON file must contain 'filters' array"
        return 1
    }
}

# File processing functions
create_output_header() {
    local -r output_file="$1"
    local -r original_url="$2"
    local -r version="$3"
    local -r timestamp="$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')"

    cat > "$output_file" << EOF
! Original: $original_url
! Version: $version
! Last modified: $timestamp
! Transformed by: https://github.com/IgorKha/mikrotik-adlist
EOF
}

resolve_version() {
    local -r file="$1"
    local -r declared="$2"

    # Registry-sourced filters carry a version in the JSON; hand-written entries
    # may leave it null, in which case fall back to the filter's own header.
    if [[ -n "$declared" && "$declared" != "null" ]]; then
        echo "$declared"
        return 0
    fi

    local detected=""
    detected=$(grep -m1 -E '^!\s*Version:' "$file" 2>/dev/null \
        | sed -E 's/^!\s*Version:\s*//' | tr -d '\r') || true

    echo "${detected:-unknown}"
}

count_hosts_entries() {
    local -r file="$1"
    grep -c '^0\.0\.0\.0 ' "$file" 2>/dev/null || echo "0"
}

is_hosts_format() {
    local -r file="$1"
    grep -q '^0\.0\.0\.0 ' "$file" 2>/dev/null
}

transform_adguard_format() {
    local -r input_file="$1"

    # Process AdGuard format: ||domain.com^ -> 0.0.0.0 domain.com
    grep -v '^!' "$input_file" 2>/dev/null | \
        grep '^||' | \
        sed -E 's/^\|\|([^$^]+)(\^.*|\$.*|$)/0.0.0.0 \1/' | \
        grep -v '^0\.0\.0\.0 $' || true
}

transform_localhost_format() {
    local -r input_file="$1"

    # Process localhost format: 127.0.0.1 domain.com -> 0.0.0.0 domain.com
    grep '^127\.0\.0\.1 ' "$input_file" 2>/dev/null | \
        sed 's/^127\.0\.0\.1 /0.0.0.0 /' || true
}

transform_plain_domains() {
    local -r input_file="$1"

    # Process plain domains: domain.com -> 0.0.0.0 domain.com
    grep -v '^!' "$input_file" 2>/dev/null | \
        grep -v '^||' | \
        grep -v '^0\.0\.0\.0 ' | \
        grep -v '^#' | \
        grep -v '^$' | \
        grep -E '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$' | \
        sed 's/^/0.0.0.0 /' || true
}

download_filter() {
    local -r url="$1"
    local -r output_file="$2"
    local -r timeout=30

    curl -fsSL --max-time "$timeout" --retry 3 --retry-delay 1 \
         -o "$output_file" "$url"
}

process_single_filter() {
    local -r filter_key="$1"
    local -r download_url="$2"
    local -r version="$3"
    local -r temp_dir="$4"

    log_info "Processing filter: $filter_key"

    local -r temp_file="$temp_dir/raw_${filter_key}.txt"
    local -r output_file="$OUTPUT_DIR/${filter_key}.txt"

    # Download filter file
    if ! download_filter "$download_url" "$temp_file"; then
        log_error "Failed to download $filter_key from $download_url"
        ((g_failed_downloads++))
        return 1
    fi

    # Create output file with header
    local resolved_version
    resolved_version=$(resolve_version "$temp_file" "$version")
    create_output_header "$output_file" "$download_url" "$resolved_version"

    local -i entries_count=0

    # Check if already in hosts format
    if is_hosts_format "$temp_file"; then
        log_info "File already in hosts format, copying as-is"
        cat "$temp_file" >> "$output_file"
        entries_count=$(count_hosts_entries "$temp_file")
    else
        # Transform different formats

        # Process AdGuard format
        local adguard_entries
        adguard_entries=$(transform_adguard_format "$temp_file")
        if [[ -n "$adguard_entries" ]]; then
            echo "$adguard_entries" >> "$output_file"
            local -i adguard_count
            adguard_count=$(echo "$adguard_entries" | wc -l)
            entries_count=$((entries_count + adguard_count))
            log_info "Transformed $adguard_count AdGuard format entries"
        fi

        # Process localhost format (127.0.0.1)
        local localhost_entries
        localhost_entries=$(transform_localhost_format "$temp_file")
        if [[ -n "$localhost_entries" ]]; then
            echo "$localhost_entries" >> "$output_file"
            local -i localhost_count
            localhost_count=$(echo "$localhost_entries" | wc -l)
            entries_count=$((entries_count + localhost_count))
            log_info "Transformed $localhost_count localhost format entries"
        fi

        # Process plain domains
        local plain_domains
        plain_domains=$(transform_plain_domains "$temp_file")
        if [[ -n "$plain_domains" ]]; then
            echo "$plain_domains" >> "$output_file"
            local -i plain_count
            plain_count=$(echo "$plain_domains" | wc -l)
            entries_count=$((entries_count + plain_count))
            log_info "Transformed $plain_count plain domain entries"
        fi
    fi

    if [[ $entries_count -gt 0 ]]; then
        log_info "Successfully processed: $filter_key ($entries_count DNS entries)"
        ((g_total_transformed += entries_count))
    else
        log_warning "No transformable content found in $filter_key"
    fi

    ((g_processed_filters++))
    return 0
}

process_all_filters() {
    local -r json_file="$1"
    local -r temp_dir="$2"

    log_info "Starting filter processing"

    # Create output directory
    mkdir -p "$OUTPUT_DIR"

    # Process each filter using jq to read JSON
    while IFS='|' read -r filter_key download_url version; do
        [[ -n "$filter_key" ]] || continue  # Skip empty lines

        process_single_filter "$filter_key" "$download_url" "$version" "$temp_dir" || true

    done < <(jq -r '.filters[] | "\(.filterKey)|\(.downloadUrl)|\(.version)"' "$json_file")
}

cleanup_and_exit() {
    local -r exit_code="${1:-0}"
    local -r temp_dir="${2:-}"

    # Cleanup temporary directory
    if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
        rm -rf "$temp_dir"
    fi

    # Print summary
    log_info "Processing complete!"
    log_info "Filters processed: $g_processed_filters"
    log_info "Failed downloads: $g_failed_downloads"
    log_info "Total DNS entries transformed: $g_total_transformed"

    # Set appropriate exit code for pipelines
    if [[ $g_failed_downloads -gt 0 ]]; then
        log_warning "Some filters failed to download"
        exit 2  # Partial failure
    fi

    exit "$exit_code"
}

# Main execution
main() {
    local json_source=""

    # Parse arguments
    case "${1:-}" in
        -h|--help)
            show_usage
            exit 0
            ;;
        "")
            log_error "Missing required argument"
            show_usage
            exit 1
            ;;
        *)
            json_source="$1"
            ;;
    esac

    # Validation
    validate_dependencies || exit 1

    # Create temporary directory
    local -r temp_dir=$(mktemp -d -t "${TEMP_DIR_PREFIX}.XXXXXX")

    # Set up cleanup trap
    trap 'cleanup_and_exit $? "$temp_dir"' EXIT INT TERM

    # Download or validate JSON file
    local json_file
    json_file=$(download_json_file "$json_source" "$temp_dir") || exit 1
    validate_json_file "$json_file" || exit 1

    # Process filters
    process_all_filters "$json_file" "$temp_dir"

    # Success
    cleanup_and_exit 0 "$temp_dir"
}

# Execute main function with all arguments
main "$@"
