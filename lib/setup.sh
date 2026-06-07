#!/usr/bin/env bash

run_setup_if_needed() {
    local app_setup="$1"
    local setup_marker_file="$2"
    local migration_marker_file="$3"
    local assets_dir="/app/public/assets"
    local assets_precompiled="false"
    local migration_fingerprint_file="/app/Gemfile.lock"
    local migration_fingerprint=""
    local last_migrated_fingerprint=""

    if [[ -d "${assets_dir}" ]] && find "${assets_dir}" -mindepth 1 -type f -print -quit >/dev/null 2>&1; then
        assets_precompiled="true"
    fi

    if [[ -z "${migration_marker_file}" ]]; then
        migration_marker_file="/config/.terminus_last_migrated_gemfile_lock_sha256"
    fi

    if [[ -f "${migration_fingerprint_file}" ]]; then
        migration_fingerprint="$(sha256sum "${migration_fingerprint_file}" | awk '{print $1}')"
    fi

    if [[ -n "${migration_fingerprint}" ]] && [[ -f "${migration_marker_file}" ]]; then
        last_migrated_fingerprint="$(tr -d '\r\n' < "${migration_marker_file}")"
    fi

    if [[ "${app_setup}" == "true" ]]; then
        if [[ -f "${setup_marker_file}" ]]; then
            echo "Skipping assets compile because setup marker exists at ${setup_marker_file}."
        elif [[ "${assets_precompiled}" == "true" ]]; then
            echo "Skipping assets compile because precompiled assets were found in ${assets_dir}."
            date -u +"%Y-%m-%dT%H:%M:%SZ" > "${setup_marker_file}"
            if id app >/dev/null 2>&1; then
                chown app:app "${setup_marker_file}"
            fi
        else
            echo "Running one-time Terminus asset setup tasks..."
            run_setup_step "assets compile" "bundle exec hanami assets compile"
            date -u +"%Y-%m-%dT%H:%M:%SZ" > "${setup_marker_file}"
            if id app >/dev/null 2>&1; then
                chown app:app "${setup_marker_file}"
            fi
            echo "Terminus asset setup completed. Marker written to ${setup_marker_file}."
        fi

        if [[ -n "${migration_fingerprint}" ]] && [[ "${last_migrated_fingerprint}" == "${migration_fingerprint}" ]]; then
            echo "Skipping database migrate because app fingerprint is unchanged."
        else
            run_setup_step "database migrate" "bundle exec hanami db migrate"
            if [[ -n "${migration_fingerprint}" ]]; then
                printf '%s' "${migration_fingerprint}" > "${migration_marker_file}"
                if id app >/dev/null 2>&1; then
                    chown app:app "${migration_marker_file}"
                fi
            fi
        fi
    else
        echo "Skipping Terminus setup tasks because app_setup is false."
    fi
}
