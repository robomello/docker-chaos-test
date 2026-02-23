#!/bin/bash
# nvme-health.sh - NVMe SMART monitoring module (read-only)
# Monitors: Percentage used, critical warnings, spare, temp, media errors
# No break/restore - hardware monitoring only

[[ -n "${_CHAOS_MOD_NVME_LOADED:-}" ]] && return 0
_CHAOS_MOD_NVME_LOADED=1

register_module "nvme-health"

nvme_health_describe() {
    cat <<EOF
Module: nvme-health
Device: ${CHAOS_NVME_DEVICE}
Mode: read-only (hardware monitoring, no fault injection)
Checks: percentage used (warn >=${CHAOS_NVME_PCT_WARN}%), critical warning, available spare (warn <=10%), temperature (warn >=${CHAOS_NVME_TEMP_WARN}C), media errors
EOF
}

_nvme_find_device() {
    if [[ "${CHAOS_NVME_DEVICE}" != "auto" ]]; then
        echo "${CHAOS_NVME_DEVICE}"
        return 0
    fi

    if [[ -e /dev/nvme0n1 ]]; then
        echo "/dev/nvme0n1"
        return 0
    fi

    local dev
    dev=$(lsblk -dno NAME,TRAN 2>/dev/null | awk '$2=="nvme" {print "/dev/"$1; exit}')
    if [[ -n "$dev" ]]; then
        echo "$dev"
        return 0
    fi

    return 1
}

nvme_health_check() {
    if ! command -v smartctl &>/dev/null; then
        log_debug "nvme-health: smartctl not available, skipping"
        return 0
    fi

    local nvme_dev
    if ! nvme_dev=$(_nvme_find_device); then
        log_debug "nvme-health: no NVMe device found, skipping"
        return 0
    fi

    log_debug "nvme-health: querying SMART data from ${nvme_dev}"

    local smart_output
    smart_output=$(sudo smartctl -A "$nvme_dev" 2>&1)
    if [[ $? -ne 0 ]] && ! echo "$smart_output" | grep -q "SMART/Health Information"; then
        log_warn "nvme-health: smartctl failed on ${nvme_dev}: $(echo "$smart_output" | head -1)"
        return 1
    fi

    local issues=()

    local pct_used
    pct_used=$(echo "$smart_output" | grep -i "Percentage Used" | awk '{print $NF}' | tr -d '%')
    if [[ "$pct_used" =~ ^[0-9]+$ ]]; then
        log_debug "nvme-health: percentage_used=${pct_used}% warn_threshold=${CHAOS_NVME_PCT_WARN}%"
        if (( pct_used >= CHAOS_NVME_PCT_WARN )); then
            issues+=("percentage used ${pct_used}% >= ${CHAOS_NVME_PCT_WARN}%")
        fi
    fi

    local crit_warn
    crit_warn=$(echo "$smart_output" | grep -i "Critical Warning" | awk '{print $NF}')
    if [[ -n "$crit_warn" ]] && [[ "$crit_warn" != "0x00" ]] && [[ "$crit_warn" != "0" ]]; then
        issues+=("critical warning ${crit_warn}")
    fi

    local spare
    spare=$(echo "$smart_output" | grep -i "Available Spare " | awk '{print $NF}' | tr -d '%')
    if [[ "$spare" =~ ^[0-9]+$ ]]; then
        log_debug "nvme-health: available_spare=${spare}%"
        if (( spare <= 10 )); then
            issues+=("available spare ${spare}% <= 10%")
        fi
    fi

    local temp
    temp=$(echo "$smart_output" | grep -i "Temperature:" | awk '{print $2}')
    if [[ "$temp" =~ ^[0-9]+$ ]]; then
        log_debug "nvme-health: temperature=${temp}C warn_threshold=${CHAOS_NVME_TEMP_WARN}C"
        if (( temp >= CHAOS_NVME_TEMP_WARN )); then
            issues+=("temperature ${temp}C >= ${CHAOS_NVME_TEMP_WARN}C")
        fi
    fi

    local media_errors
    media_errors=$(echo "$smart_output" | grep -i "Media and Data Integrity Errors" | awk '{print $NF}')
    if [[ "$media_errors" =~ ^[0-9]+$ ]] && (( media_errors > 0 )); then
        issues+=("media and data integrity errors: ${media_errors}")
    fi

    if [[ ${#issues[@]} -eq 0 ]]; then
        log_debug "nvme-health: all checks passed for ${nvme_dev}"
        return 0
    fi

    local summary
    summary=$(printf "; %s" "${issues[@]}")
    summary="${summary:2}"
    log_warn "nvme-health: ${nvme_dev}: ${summary}"
    send_alert "NVMe health warning on ${nvme_dev}: ${summary}" "warn"
    return 1
}

nvme_health_break() {
    log_warn "nvme-health is read-only, no break supported"
    return 1
}

nvme_health_heal() {
    log_info "nvme-health: no automated healing for hardware"
    return 0
}

nvme_health_restore() {
    log_info "nvme-health: nothing to restore"
    return 0
}
