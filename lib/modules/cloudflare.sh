#!/bin/bash
# cloudflare.sh - Cloudflare tunnel chaos module
# Injects: Stops the tunnel container to break external access
# Heals: Restarts container and verifies clean logs

[[ -n "${_CHAOS_MOD_CLOUDFLARE_LOADED:-}" ]] && return 0
_CHAOS_MOD_CLOUDFLARE_LOADED=1

register_module "cloudflare"

_CF_ERR_PATTERN="ERR|failed to connect|connection refused|tunnel disconnected|Register tunnel error"

cloudflare_describe() {
    echo "Cloudflare tunnel container ($CHAOS_CLOUDFLARE_CONTAINER) stop/start"
}

cloudflare_check() {
    if ! is_container_running "$CHAOS_CLOUDFLARE_CONTAINER"; then
        log_debug "cloudflare: container not running"
        return 1
    fi

    local last_5
    last_5=$(docker logs --tail 5 "$CHAOS_CLOUDFLARE_CONTAINER" 2>&1)

    if echo "$last_5" | grep -qiE "$_CF_ERR_PATTERN"; then
        log_debug "cloudflare: error pattern found in recent logs"
        return 1
    fi

    return 0
}

cloudflare_break() {
    local was_running="false"
    if is_container_running "$CHAOS_CLOUDFLARE_CONTAINER"; then
        was_running="true"
    fi

    save_snapshot "cloudflare" "was_running" "$was_running"

    if [[ "$was_running" != "true" ]]; then
        log_warn "cloudflare: container already stopped, nothing to break"
        return 0
    fi

    if [[ "$CHAOS_DRY_RUN" == "true" ]]; then
        log_action "cloudflare [DRY-RUN]: would docker stop $CHAOS_CLOUDFLARE_CONTAINER"
        return 0
    fi

    log_action "cloudflare: stopping $CHAOS_CLOUDFLARE_CONTAINER"
    if ! docker stop "$CHAOS_CLOUDFLARE_CONTAINER" &>/dev/null; then
        log_error "cloudflare: docker stop failed"
        return 1
    fi

    if is_container_running "$CHAOS_CLOUDFLARE_CONTAINER"; then
        log_error "cloudflare: container still running after stop"
        return 1
    fi

    log_info "cloudflare: container stopped, tunnel is down"
    send_alert "Cloudflare tunnel container $CHAOS_CLOUDFLARE_CONTAINER stopped" "warn"
    return 0
}

cloudflare_heal() {
    if [[ "$CHAOS_DRY_RUN" == "true" ]]; then
        log_action "cloudflare [DRY-RUN]: would docker start $CHAOS_CLOUDFLARE_CONTAINER and verify logs"
        return 0
    fi

    if is_container_running "$CHAOS_CLOUDFLARE_CONTAINER"; then
        log_action "cloudflare: container already running, restarting to clear error state"
        docker restart "$CHAOS_CLOUDFLARE_CONTAINER" &>/dev/null
    else
        log_action "cloudflare: starting $CHAOS_CLOUDFLARE_CONTAINER"
        if ! docker start "$CHAOS_CLOUDFLARE_CONTAINER" &>/dev/null; then
            log_error "cloudflare: docker start failed"
            return 1
        fi
    fi

    sleep 5

    local post_logs
    post_logs=$(docker logs --tail 5 "$CHAOS_CLOUDFLARE_CONTAINER" 2>&1)

    if echo "$post_logs" | grep -qiE "$_CF_ERR_PATTERN"; then
        log_error "cloudflare: errors still present after heal"
        return 1
    fi

    log_info "cloudflare: heal successful, tunnel logs clean"
    send_alert "Cloudflare tunnel container $CHAOS_CLOUDFLARE_CONTAINER restarted and healthy" "info"
    return 0
}

cloudflare_restore() {
    local was_running
    was_running=$(get_snapshot "cloudflare" "was_running")

    if [[ "$was_running" != "true" ]]; then
        log_info "cloudflare: was not running before break, leaving stopped"
        return 0
    fi

    if [[ "$CHAOS_DRY_RUN" == "true" ]]; then
        log_action "cloudflare [DRY-RUN]: would docker start $CHAOS_CLOUDFLARE_CONTAINER"
        return 0
    fi

    if is_container_running "$CHAOS_CLOUDFLARE_CONTAINER"; then
        log_info "cloudflare: container already running"
        return 0
    fi

    log_action "cloudflare: emergency restore - starting $CHAOS_CLOUDFLARE_CONTAINER"
    if ! docker start "$CHAOS_CLOUDFLARE_CONTAINER" &>/dev/null; then
        log_error "cloudflare: emergency restore docker start failed"
        return 1
    fi

    sleep 5

    if ! is_container_running "$CHAOS_CLOUDFLARE_CONTAINER"; then
        log_error "cloudflare: container not running after restore"
        return 1
    fi

    local post_logs
    post_logs=$(docker logs --tail 5 "$CHAOS_CLOUDFLARE_CONTAINER" 2>&1)

    if echo "$post_logs" | grep -qiE "$_CF_ERR_PATTERN"; then
        log_warn "cloudflare: restored but logs show errors - tunnel may need reconnect time"
    else
        log_info "cloudflare: emergency restore complete, logs clean"
    fi

    send_alert "Cloudflare tunnel container $CHAOS_CLOUDFLARE_CONTAINER emergency restore completed" "info"
    return 0
}
