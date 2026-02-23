#!/bin/bash
# dns.sh - DNS resolution chaos module
# Injects: Corrupts /etc/resolv.conf to break host DNS
# Heals: Restores resolv.conf + restarts systemd-resolved

[[ -n "${_CHAOS_MOD_DNS_LOADED:-}" ]] && return 0
_CHAOS_MOD_DNS_LOADED=1

register_module "dns"

# ── Helpers ───────────────────────────────────────────────────────────────

_dns_test_host() {
    if command -v dig &>/dev/null; then
        dig +short +timeout=5 "$CHAOS_DNS_TEST_HOST" 2>/dev/null | grep -q '.'
    else
        host "$CHAOS_DNS_TEST_HOST" &>/dev/null
    fi
}

_dns_test_container() {
    [[ -n "$CHAOS_DNS_TEST_CONTAINER" ]] || return 1
    is_container_running "$CHAOS_DNS_TEST_CONTAINER" || return 1
    docker exec "$CHAOS_DNS_TEST_CONTAINER" python3 -c \
        "import socket; socket.setdefaulttimeout(5); socket.gethostbyname('$CHAOS_DNS_TEST_HOST')" \
        &>/dev/null 2>&1
}

# ── Interface ─────────────────────────────────────────────────────────────

dns_describe() {
    cat <<'EOF'
Module: dns
  Chaos: Overwrites /etc/resolv.conf with an unreachable nameserver to sever host DNS resolution.
  Heals: Restarts systemd-resolved; falls back to restoring /etc/resolv.conf from snapshot.
  Check: Verifies host DNS via dig/host; optionally tests container DNS via python3 socket.
  Deps:  dig or host (host check), python3 (container check), sudo, systemd-resolved
EOF
}

dns_check() {
    log_debug "dns_check: testing host DNS for $CHAOS_DNS_TEST_HOST"

    local host_ok=0
    if _dns_test_host; then
        host_ok=1
        log_debug "dns_check: host DNS OK"
    else
        log_warn "dns_check: host DNS resolution failed for $CHAOS_DNS_TEST_HOST"
    fi

    if [[ -n "$CHAOS_DNS_TEST_CONTAINER" ]]; then
        if is_container_running "$CHAOS_DNS_TEST_CONTAINER"; then
            if _dns_test_container; then
                log_debug "dns_check: container DNS OK ($CHAOS_DNS_TEST_CONTAINER)"
            else
                log_warn "dns_check: container DNS failed ($CHAOS_DNS_TEST_CONTAINER)"
            fi
        else
            log_debug "dns_check: container $CHAOS_DNS_TEST_CONTAINER not running, skipping"
        fi
    fi

    if (( host_ok )); then
        return 0
    fi
    return 1
}

dns_break() {
    if [[ "$CHAOS_DRY_RUN" == "true" ]]; then
        log_action "dns_break: [DRY RUN] would corrupt /etc/resolv.conf"
        return 0
    fi

    log_action "dns_break: saving /etc/resolv.conf snapshot"
    local original
    original=$(cat /etc/resolv.conf 2>/dev/null)
    if [[ -z "$original" ]]; then
        log_error "dns_break: /etc/resolv.conf is empty or unreadable"
        return 1
    fi
    save_snapshot "dns" "resolv_conf" "$original"

    log_action "dns_break: replacing /etc/resolv.conf with broken nameserver"
    if ! echo "nameserver 127.0.0.254" | sudo tee /etc/resolv.conf &>/dev/null; then
        log_error "dns_break: failed to write /etc/resolv.conf"
        return 1
    fi

    sleep 1

    if _dns_test_host; then
        log_warn "dns_break: host DNS still resolves after corruption (cached or stub resolver active)"
        send_alert "dns_break: DNS still resolving after /etc/resolv.conf corruption - stub resolver may be caching" "warn"
        return 0
    fi

    log_info "dns_break: host DNS is broken"
    send_alert "Chaos injected: DNS resolution broken via corrupted /etc/resolv.conf" "warn"
    return 0
}

dns_heal() {
    if [[ "$CHAOS_DRY_RUN" == "true" ]]; then
        log_action "dns_heal: [DRY RUN] would restart systemd-resolved and restore /etc/resolv.conf"
        return 0
    fi

    log_action "dns_heal: restarting systemd-resolved"
    if sudo systemctl restart systemd-resolved 2>/dev/null; then
        sleep 3
        if _dns_test_host; then
            log_info "dns_heal: host DNS restored via systemd-resolved restart"
            send_alert "DNS healed: systemd-resolved restart succeeded" "info"
            _dns_heal_container
            return 0
        fi
        log_warn "dns_heal: systemd-resolved restart did not restore DNS, falling back to resolv.conf restore"
    else
        log_warn "dns_heal: systemd-resolved restart failed, falling back to resolv.conf restore"
    fi

    local saved
    saved=$(get_snapshot "dns" "resolv_conf")
    if [[ -z "$saved" ]]; then
        log_error "dns_heal: no resolv.conf snapshot found, cannot restore"
        send_alert "DNS heal failed: no snapshot available" "error"
        return 1
    fi

    log_action "dns_heal: restoring /etc/resolv.conf from snapshot"
    if ! echo "$saved" | sudo tee /etc/resolv.conf &>/dev/null; then
        log_error "dns_heal: failed to restore /etc/resolv.conf"
        send_alert "DNS heal failed: could not write /etc/resolv.conf" "error"
        return 1
    fi

    sleep 2

    if _dns_test_host; then
        log_info "dns_heal: host DNS restored via resolv.conf snapshot"
        send_alert "DNS healed: /etc/resolv.conf restored from snapshot" "info"
        _dns_heal_container
        return 0
    fi

    log_error "dns_heal: host DNS still broken after all recovery attempts"
    send_alert "DNS heal FAILED: host DNS still broken after resolv.conf restore" "error"
    return 1
}

_dns_heal_container() {
    [[ -n "$CHAOS_DNS_TEST_CONTAINER" ]] || return 0
    is_container_running "$CHAOS_DNS_TEST_CONTAINER" || return 0

    if ! _dns_test_container; then
        log_action "dns_heal: restarting container $CHAOS_DNS_TEST_CONTAINER for DNS recovery"
        docker restart "$CHAOS_DNS_TEST_CONTAINER" &>/dev/null || true
        sleep 5
        if _dns_test_container; then
            log_info "dns_heal: container DNS restored after restart"
        else
            log_warn "dns_heal: container DNS still failing after restart"
        fi
    fi
}

dns_restore() {
    if [[ "$CHAOS_DRY_RUN" == "true" ]]; then
        log_action "dns_restore: [DRY RUN] would restore /etc/resolv.conf and restart systemd-resolved"
        return 0
    fi

    local saved
    saved=$(get_snapshot "dns" "resolv_conf")
    if [[ -n "$saved" ]]; then
        log_action "dns_restore: restoring /etc/resolv.conf from snapshot"
        if echo "$saved" | sudo tee /etc/resolv.conf &>/dev/null; then
            log_info "dns_restore: /etc/resolv.conf restored"
        else
            log_error "dns_restore: failed to restore /etc/resolv.conf"
        fi
    else
        log_debug "dns_restore: no snapshot found, skipping resolv.conf restore"
    fi

    log_action "dns_restore: restarting systemd-resolved"
    if sudo systemctl restart systemd-resolved 2>/dev/null; then
        sleep 3
        if _dns_test_host; then
            log_info "dns_restore: DNS fully operational"
        else
            log_warn "dns_restore: DNS still not resolving after restore"
        fi
    else
        log_warn "dns_restore: systemd-resolved restart failed"
    fi
}
