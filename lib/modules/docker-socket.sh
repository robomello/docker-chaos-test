#!/bin/bash
# docker-socket.sh - Docker socket permissions chaos module
# Injects: Changes socket group ownership to break Docker access
# Heals: Restores correct group + permissions

[[ -n "${_CHAOS_MOD_DOCKER_SOCKET_LOADED:-}" ]] && return 0
_CHAOS_MOD_DOCKER_SOCKET_LOADED=1

register_module "docker-socket"

docker_socket_describe() {
    echo "Docker socket permissions (group ownership + chmod)"
}

docker_socket_check() {
    local current_group
    current_group=$(stat -c '%G' "$CHAOS_DOCKER_SOCKET" 2>/dev/null) || {
        log_error "docker-socket: cannot stat $CHAOS_DOCKER_SOCKET"
        return 1
    }

    if [[ "$current_group" != "$CHAOS_DOCKER_GROUP" ]]; then
        log_debug "docker-socket: socket group is '$current_group', expected '$CHAOS_DOCKER_GROUP'"
        return 1
    fi

    if ! docker info &>/dev/null; then
        log_debug "docker-socket: group is correct but docker daemon not responding"
        return 1
    fi

    return 0
}

docker_socket_break() {
    local current_group current_perms

    current_group=$(stat -c '%G' "$CHAOS_DOCKER_SOCKET" 2>/dev/null) || {
        log_error "docker-socket: cannot stat $CHAOS_DOCKER_SOCKET"
        return 1
    }
    current_perms=$(stat -c '%a' "$CHAOS_DOCKER_SOCKET" 2>/dev/null) || {
        log_error "docker-socket: cannot read permissions on $CHAOS_DOCKER_SOCKET"
        return 1
    }

    save_snapshot "docker-socket" "group" "$current_group"
    save_snapshot "docker-socket" "perms" "$current_perms"
    log_debug "docker-socket: snapshot saved (group=$current_group, perms=$current_perms)"

    if [[ "$CHAOS_DRY_RUN" == "true" ]]; then
        log_action "docker-socket [DRY-RUN]: would chgrp nogroup $CHAOS_DOCKER_SOCKET"
        return 0
    fi

    log_action "docker-socket: changing socket group to 'nogroup'"
    if ! sudo chgrp nogroup "$CHAOS_DOCKER_SOCKET" 2>&1; then
        log_error "docker-socket: chgrp nogroup failed"
        return 1
    fi

    if docker info &>/dev/null; then
        log_warn "docker-socket: group changed but docker info still succeeds (user may be root)"
    else
        log_info "docker-socket: break confirmed - docker info now fails"
    fi

    send_alert "Docker socket group changed to 'nogroup' on $CHAOS_DOCKER_SOCKET" "warn"
    return 0
}

docker_socket_heal() {
    local current_group
    current_group=$(stat -c '%G' "$CHAOS_DOCKER_SOCKET" 2>/dev/null) || {
        log_error "docker-socket: cannot stat $CHAOS_DOCKER_SOCKET"
        return 1
    }

    if [[ "$current_group" == "$CHAOS_DOCKER_GROUP" ]] && docker info &>/dev/null; then
        log_info "docker-socket: already healthy (group=$current_group)"
        return 0
    fi

    if [[ "$CHAOS_DRY_RUN" == "true" ]]; then
        log_action "docker-socket [DRY-RUN]: would chgrp $CHAOS_DOCKER_GROUP $CHAOS_DOCKER_SOCKET && chmod 660"
        return 0
    fi

    log_action "docker-socket: restoring group to '$CHAOS_DOCKER_GROUP' and permissions to 660"

    if ! sudo chgrp "$CHAOS_DOCKER_GROUP" "$CHAOS_DOCKER_SOCKET" 2>&1; then
        log_error "docker-socket: chgrp $CHAOS_DOCKER_GROUP failed"
        return 1
    fi

    if ! sudo chmod 660 "$CHAOS_DOCKER_SOCKET" 2>&1; then
        log_error "docker-socket: chmod 660 failed"
        return 1
    fi

    if docker info &>/dev/null; then
        log_info "docker-socket: heal successful"
        send_alert "Docker socket permissions restored on $CHAOS_DOCKER_SOCKET" "info"
        return 0
    fi

    log_error "docker-socket: group/perms restored but docker info still fails"
    return 1
}

docker_socket_restore() {
    local saved_group saved_perms
    saved_group=$(get_snapshot "docker-socket" "group")
    saved_perms=$(get_snapshot "docker-socket" "perms")

    if [[ -z "$saved_group" ]] || [[ -z "$saved_perms" ]]; then
        log_error "docker-socket: no snapshot found, cannot restore"
        return 1
    fi

    if [[ "$CHAOS_DRY_RUN" == "true" ]]; then
        log_action "docker-socket [DRY-RUN]: would restore group=$saved_group perms=$saved_perms"
        return 0
    fi

    log_action "docker-socket: emergency restore (group=$saved_group, perms=$saved_perms)"

    if ! sudo chgrp "$saved_group" "$CHAOS_DOCKER_SOCKET" 2>&1; then
        log_error "docker-socket: restore chgrp '$saved_group' failed"
        return 1
    fi

    if ! sudo chmod "$saved_perms" "$CHAOS_DOCKER_SOCKET" 2>&1; then
        log_error "docker-socket: restore chmod $saved_perms failed"
        return 1
    fi

    log_info "docker-socket: emergency restore complete (group=$saved_group, perms=$saved_perms)"
    send_alert "Docker socket emergency restore completed on $CHAOS_DOCKER_SOCKET" "info"
    return 0
}
