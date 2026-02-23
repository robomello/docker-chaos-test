#!/bin/bash
# disk-space.sh - Disk space chaos module
# Injects: Creates a large temp file to fill disk (leaves CHAOS_DISK_RESERVE_MB free)
# Heals: Prunes Docker images/builders/networks, removes fill file

[[ -n "${_CHAOS_MOD_DISK_SPACE_LOADED:-}" ]] && return 0
_CHAOS_MOD_DISK_SPACE_LOADED=1

register_module "disk-space"

# ── Helpers ───────────────────────────────────────────────────────────────

_disk_usage_pct() {
    df "$1" --output=pcent 2>/dev/null | tail -1 | tr -d ' %'
}

_disk_avail_mb() {
    df "$1" --output=avail 2>/dev/null | tail -1 | awk '{printf "%d", $1/1024}'
}

_disk_fill_path() {
    echo "${CHAOS_STATE_DIR}/disk-fill"
}

# ── Interface ─────────────────────────────────────────────────────────────

disk_space_describe() {
    cat <<'EOF'
Module: disk-space
  Chaos: Fills the first configured mount with a large sparse file, leaving only
         CHAOS_DISK_RESERVE_MB free. Uses dd from /dev/zero.
  Heals: Removes fill file; prunes Docker images, builders, and networks (no container/volume prune).
  Check: Reads usage % on each mount in CHAOS_DISK_MOUNTS via df --output=pcent.
  Deps:  df, dd, docker
EOF
}

disk_space_check() {
    local any_critical=0
    local mount usage

    for mount in $CHAOS_DISK_MOUNTS; do
        usage=$(_disk_usage_pct "$mount")
        if [[ -z "$usage" || ! "$usage" =~ ^[0-9]+$ ]]; then
            log_warn "disk_space_check: could not read usage for $mount"
            continue
        fi

        log_debug "disk_space_check: $mount usage=${usage}%"

        if (( usage >= CHAOS_DISK_CRIT_PCT )); then
            log_warn "disk_space_check: $mount at ${usage}% (>= crit ${CHAOS_DISK_CRIT_PCT}%)"
            any_critical=1
        elif (( usage >= CHAOS_DISK_WARN_PCT )); then
            log_warn "disk_space_check: $mount at ${usage}% (>= warn ${CHAOS_DISK_WARN_PCT}%)"
        fi
    done

    return $any_critical
}

disk_space_break() {
    if [[ "$CHAOS_DRY_RUN" == "true" ]]; then
        log_action "disk_space_break: [DRY RUN] would fill first mount leaving ${CHAOS_DISK_RESERVE_MB}MB free"
        return 0
    fi

    local first_mount
    first_mount=$(echo "$CHAOS_DISK_MOUNTS" | awk '{print $1}')

    local avail_mb
    avail_mb=$(_disk_avail_mb "$first_mount")
    if [[ -z "$avail_mb" || ! "$avail_mb" =~ ^[0-9]+$ ]]; then
        log_error "disk_space_break: could not determine available space on $first_mount"
        return 1
    fi

    local fill_mb=$(( avail_mb - CHAOS_DISK_RESERVE_MB ))
    if (( fill_mb <= 0 )); then
        log_warn "disk_space_break: already within ${CHAOS_DISK_RESERVE_MB}MB reserve on $first_mount (avail=${avail_mb}MB), skipping"
        return 0
    fi

    local fill_path
    fill_path=$(_disk_fill_path)
    save_snapshot "disk-space" "fill_path" "$fill_path"

    log_action "disk_space_break: filling ${fill_mb}MB on $first_mount (avail=${avail_mb}MB, reserve=${CHAOS_DISK_RESERVE_MB}MB)"
    if ! dd if=/dev/zero of="$fill_path" bs=1M count="$fill_mb" 2>/dev/null; then
        log_error "disk_space_break: dd failed (disk may have hit actual limit)"
    fi

    local usage_after
    usage_after=$(_disk_usage_pct "$first_mount")
    log_info "disk_space_break: $first_mount now at ${usage_after}% after fill"

    if (( usage_after >= CHAOS_DISK_WARN_PCT )); then
        send_alert "Chaos injected: disk $first_mount filled to ${usage_after}% (fill file: $fill_path)" "warn"
    else
        log_warn "disk_space_break: fill created but usage ${usage_after}% still below warn threshold"
    fi

    return 0
}

disk_space_heal() {
    if [[ "$CHAOS_DRY_RUN" == "true" ]]; then
        log_action "disk_space_heal: [DRY RUN] would prune Docker images/builders/networks and remove fill file"
        return 0
    fi

    local fill_path
    fill_path=$(_disk_fill_path)
    if [[ -f "$fill_path" ]]; then
        log_action "disk_space_heal: removing fill file $fill_path"
        rm -f "$fill_path"
    fi

    log_action "disk_space_heal: pruning Docker images (until=24h)"
    docker image prune -f --filter "until=24h" &>/dev/null || true

    log_action "disk_space_heal: pruning Docker builder cache"
    docker builder prune -f &>/dev/null || true

    log_action "disk_space_heal: pruning Docker networks (until=24h)"
    docker network prune -f --filter "until=24h" &>/dev/null || true

    local mount usage_after any_critical=0
    for mount in $CHAOS_DISK_MOUNTS; do
        usage_after=$(_disk_usage_pct "$mount")
        log_info "disk_space_heal: $mount now at ${usage_after}% after cleanup"
        if [[ -n "$usage_after" && "$usage_after" =~ ^[0-9]+$ ]] && (( usage_after >= CHAOS_DISK_CRIT_PCT )); then
            any_critical=1
        fi
    done

    if (( any_critical )); then
        log_warn "disk_space_heal: disk still critical after cleanup"
        send_alert "Disk heal incomplete: one or more mounts still above ${CHAOS_DISK_CRIT_PCT}%" "warn"
        return 1
    fi

    send_alert "Disk healed: Docker prune complete, fill file removed" "info"
    return 0
}

disk_space_restore() {
    if [[ "$CHAOS_DRY_RUN" == "true" ]]; then
        log_action "disk_space_restore: [DRY RUN] would remove fill file from snapshot path"
        return 0
    fi

    local saved_path
    saved_path=$(get_snapshot "disk-space" "fill_path")

    local fill_path
    fill_path=$(_disk_fill_path)

    for path in "$saved_path" "$fill_path"; do
        [[ -n "$path" && -f "$path" ]] || continue
        log_action "disk_space_restore: removing fill file $path"
        rm -f "$path"
    done

    local mount usage
    for mount in $CHAOS_DISK_MOUNTS; do
        usage=$(_disk_usage_pct "$mount")
        if [[ -n "$usage" && "$usage" =~ ^[0-9]+$ ]] && (( usage < CHAOS_DISK_WARN_PCT )); then
            log_info "disk_space_restore: $mount at ${usage}% - normal"
        else
            log_warn "disk_space_restore: $mount at ${usage}% - still elevated"
        fi
    done
}
