#!/bin/bash
# postgres.sh - PostgreSQL health chaos module
# Injects: Pauses Postgres container to simulate unresponsive DB
# Heals: Unpauses or restarts container, cleans idle connections

[[ -n "${_CHAOS_MOD_POSTGRES_LOADED:-}" ]] && return 0
_CHAOS_MOD_POSTGRES_LOADED=1

register_module "postgres"

postgres_describe() {
    cat <<EOF
Module: postgres
Container: ${CHAOS_POSTGRES_CONTAINER}
Break: docker pause (simulates unresponsive DB)
Heal: unpause + idle connection cleanup
Restore: unpause/restart + pg_isready wait
Threshold: ${CHAOS_POSTGRES_CONN_THRESHOLD}/${CHAOS_POSTGRES_MAX_CONN} connections
EOF
}

postgres_check() {
    if ! is_container_running "$CHAOS_POSTGRES_CONTAINER"; then
        log_debug "postgres: container not running, skipping"
        return 0
    fi

    local status
    status=$(docker inspect -f '{{.State.Status}}' "$CHAOS_POSTGRES_CONTAINER" 2>/dev/null)
    if [[ "$status" == "paused" ]]; then
        log_warn "postgres: container is paused"
        return 1
    fi

    if ! docker exec "$CHAOS_POSTGRES_CONTAINER" pg_isready -U "$CHAOS_POSTGRES_USER" &>/dev/null; then
        log_warn "postgres: pg_isready failed"
        return 1
    fi

    local conn_count
    conn_count=$(docker exec "$CHAOS_POSTGRES_CONTAINER" \
        psql -U "$CHAOS_POSTGRES_USER" -t -c \
        "SELECT count(*) FROM pg_stat_activity;" 2>/dev/null | tr -d ' \n')

    if [[ -z "$conn_count" ]] || ! [[ "$conn_count" =~ ^[0-9]+$ ]]; then
        log_warn "postgres: could not read connection count"
        return 1
    fi

    log_debug "postgres: connections=${conn_count} threshold=${CHAOS_POSTGRES_CONN_THRESHOLD}"

    if (( conn_count >= CHAOS_POSTGRES_CONN_THRESHOLD )); then
        log_warn "postgres: connection count ${conn_count} >= threshold ${CHAOS_POSTGRES_CONN_THRESHOLD}"
        return 1
    fi

    return 0
}

postgres_break() {
    if ! is_container_running "$CHAOS_POSTGRES_CONTAINER"; then
        log_warn "postgres: container not running, cannot inject fault"
        return 1
    fi

    local prior_status
    prior_status=$(docker inspect -f '{{.State.Status}}' "$CHAOS_POSTGRES_CONTAINER" 2>/dev/null)
    save_snapshot "postgres" "prior_status" "$prior_status"
    log_debug "postgres: saved prior_status=${prior_status}"

    log_action "postgres: pausing container ${CHAOS_POSTGRES_CONTAINER}"
    if [[ "$CHAOS_DRY_RUN" == "true" ]]; then
        log_info "postgres: [dry-run] would pause ${CHAOS_POSTGRES_CONTAINER}"
        return 0
    fi

    if ! docker pause "$CHAOS_POSTGRES_CONTAINER" &>/dev/null; then
        log_error "postgres: failed to pause container"
        return 1
    fi

    sleep 1
    if docker exec "$CHAOS_POSTGRES_CONTAINER" pg_isready -U "$CHAOS_POSTGRES_USER" &>/dev/null 2>&1; then
        log_warn "postgres: pg_isready still succeeds after pause (unexpected)"
        return 1
    fi

    log_info "postgres: fault injected - container paused, pg_isready fails as expected"
    return 0
}

_postgres_terminate_idle_connections() {
    local terminated
    terminated=$(docker exec "$CHAOS_POSTGRES_CONTAINER" \
        psql -U "$CHAOS_POSTGRES_USER" -t -c \
        "SELECT count(*) FROM (
            SELECT pg_terminate_backend(pid)
            FROM pg_stat_activity
            WHERE state = 'idle'
              AND query_start < now() - interval '10 minutes'
              AND pid <> pg_backend_pid()
        ) t;" 2>/dev/null | tr -d ' \n')
    log_info "postgres: terminated ${terminated:-0} idle connections older than 10 minutes"
}

postgres_heal() {
    local status
    status=$(docker inspect -f '{{.State.Status}}' "$CHAOS_POSTGRES_CONTAINER" 2>/dev/null)

    if [[ "$status" == "paused" ]]; then
        log_action "postgres: unpausing ${CHAOS_POSTGRES_CONTAINER}"
        if [[ "$CHAOS_DRY_RUN" == "true" ]]; then
            log_info "postgres: [dry-run] would unpause ${CHAOS_POSTGRES_CONTAINER}"
            return 0
        fi
        if ! docker unpause "$CHAOS_POSTGRES_CONTAINER" &>/dev/null; then
            log_error "postgres: failed to unpause container"
            send_alert "postgres heal failed: could not unpause ${CHAOS_POSTGRES_CONTAINER}" "error"
            return 1
        fi
    elif ! is_container_running "$CHAOS_POSTGRES_CONTAINER"; then
        log_warn "postgres: container not running during heal, nothing to do"
        return 1
    fi

    log_debug "postgres: waiting for pg_isready after heal"
    local ready=false
    local i
    for (( i=0; i<30; i++ )); do
        if docker exec "$CHAOS_POSTGRES_CONTAINER" pg_isready -U "$CHAOS_POSTGRES_USER" &>/dev/null; then
            ready=true
            break
        fi
        sleep 1
    done

    if [[ "$ready" != "true" ]]; then
        log_error "postgres: pg_isready did not recover within 30s"
        send_alert "postgres heal failed: pg_isready timeout on ${CHAOS_POSTGRES_CONTAINER}" "error"
        return 1
    fi

    local conn_count
    conn_count=$(docker exec "$CHAOS_POSTGRES_CONTAINER" \
        psql -U "$CHAOS_POSTGRES_USER" -t -c \
        "SELECT count(*) FROM pg_stat_activity;" 2>/dev/null | tr -d ' \n')

    if [[ "$conn_count" =~ ^[0-9]+$ ]] && (( conn_count >= CHAOS_POSTGRES_CONN_THRESHOLD )); then
        log_warn "postgres: connection count ${conn_count} still high after heal, terminating idle"
        _postgres_terminate_idle_connections
    fi

    log_info "postgres: heal complete - pg_isready ok, connections=${conn_count:-?}"
    send_alert "postgres healed: ${CHAOS_POSTGRES_CONTAINER} unpaused and accepting connections" "info"
    return 0
}

postgres_restore() {
    local status
    status=$(docker inspect -f '{{.State.Status}}' "$CHAOS_POSTGRES_CONTAINER" 2>/dev/null)

    if [[ "$status" == "paused" ]]; then
        log_action "postgres: unpausing ${CHAOS_POSTGRES_CONTAINER} during restore"
        if [[ "$CHAOS_DRY_RUN" != "true" ]]; then
            docker unpause "$CHAOS_POSTGRES_CONTAINER" &>/dev/null
        fi
    fi

    if ! is_container_running "$CHAOS_POSTGRES_CONTAINER"; then
        log_warn "postgres: container not running after unpause, skipping restore"
        return 1
    fi

    log_debug "postgres: waiting for pg_isready during restore"
    local i
    for (( i=0; i<60; i++ )); do
        if docker exec "$CHAOS_POSTGRES_CONTAINER" pg_isready -U "$CHAOS_POSTGRES_USER" &>/dev/null; then
            log_info "postgres: restore complete - pg_isready ok after ${i}s"
            return 0
        fi
        sleep 1
    done

    log_warn "postgres: pg_isready failed after 60s, attempting container restart"
    if [[ "$CHAOS_DRY_RUN" == "true" ]]; then
        log_info "postgres: [dry-run] would restart ${CHAOS_POSTGRES_CONTAINER}"
        return 0
    fi

    docker restart "$CHAOS_POSTGRES_CONTAINER" &>/dev/null

    for (( i=0; i<60; i++ )); do
        if docker exec "$CHAOS_POSTGRES_CONTAINER" pg_isready -U "$CHAOS_POSTGRES_USER" &>/dev/null; then
            log_info "postgres: restore complete after restart - pg_isready ok after ${i}s"
            return 0
        fi
        sleep 1
    done

    log_error "postgres: restore failed - pg_isready timeout after restart"
    send_alert "postgres restore failed: ${CHAOS_POSTGRES_CONTAINER} not accepting connections" "error"
    return 1
}
