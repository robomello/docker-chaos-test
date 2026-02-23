#!/bin/bash
# self-heal.sh - Self-healing library for system watchers
# Source this file to get all healing functions.
# Usage:
#   source /path/to/lib/self-heal.sh
#   run_all_health_checks
#   # or individual:
#   docker_socket_check && echo "ok" || docker_socket_heal

[[ -n "${_CHAOS_SELF_HEAL_LOADED:-}" ]] && return 0
_CHAOS_SELF_HEAL_LOADED=1

# Resolve our directory
SELF_HEAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common utilities
source "$SELF_HEAL_DIR/common.sh"

# Source all modules
for _mod_file in "$SELF_HEAL_DIR/modules/"*.sh; do
    if [[ -f "$_mod_file" ]]; then
        source "$_mod_file"
    fi
done
unset _mod_file

# Source fleet verification
source "$SELF_HEAL_DIR/fleet.sh"

# ── Internal Helper ───────────────────────────────────────────────────

_fn() {
    # Normalize module name to function name prefix (hyphens -> underscores)
    echo "${1//-/_}"
}

# ── Convenience Functions ─────────────────────────────────────────────

run_all_health_checks() {
    # Run all registered module checks, heal if broken.
    # Returns: number of modules that failed to heal.

    [[ -z "$CHAOS_STATE_DIR" ]] && init_state_dir

    local pass=0 fail=0 module fn check_fn heal_fn

    for module in "${CHAOS_MODULES[@]}"; do
        fn="$(_fn "$module")"
        check_fn="${fn}_check"
        heal_fn="${fn}_heal"

        if ! declare -f "$check_fn" &>/dev/null; then
            log_warn "self-heal: check function '$check_fn' not found, skipping '$module'"
            continue
        fi

        log_debug "self-heal: checking $module"

        if "$check_fn"; then
            log_result "pass" "$module"
            (( pass++ ))
        else
            log_warn "self-heal: $module is unhealthy, attempting heal"
            if declare -f "$heal_fn" &>/dev/null && "$heal_fn"; then
                log_result "pass" "$module (healed)"
                (( pass++ ))
            else
                log_result "fail" "$module (heal failed)"
                (( fail++ ))
            fi
        fi
    done

    # Fleet verification (if CHAOS_FLEET_SERVICES is configured)
    if [[ -n "${CHAOS_FLEET_SERVICES+x}" ]] && [[ ${#CHAOS_FLEET_SERVICES[@]} -gt 0 ]]; then
        log_debug "self-heal: running fleet verification"
        fleet_init
        fleet_snapshot >/dev/null
        if ! fleet_verify; then
            log_warn "self-heal: fleet has ${#FLEET_DAMAGED[@]} damaged containers"
            fleet_heal || (( fail += ${#FLEET_STILL_BROKEN[@]} ))
        fi
    fi

    log_info "self-heal: summary - ${pass} passed, ${fail} failed"
    return "$fail"
}

run_module_check() {
    # Run a single module's check + heal cycle.
    # Usage: run_module_check <module-name>
    # Returns: 0 if healthy (or healed), 1 if heal failed, 2 if module unknown.

    local module=$1
    if ! is_module_registered "$module"; then
        log_error "self-heal: module '$module' is not registered"
        return 2
    fi

    local fn check_fn heal_fn
    fn="$(_fn "$module")"
    check_fn="${fn}_check"
    heal_fn="${fn}_heal"

    if ! declare -f "$check_fn" &>/dev/null; then
        log_error "self-heal: check function '$check_fn' not found for module '$module'"
        return 2
    fi

    if "$check_fn"; then
        log_result "pass" "$module"
        return 0
    fi

    log_warn "self-heal: $module unhealthy, attempting heal"
    if declare -f "$heal_fn" &>/dev/null && "$heal_fn"; then
        log_result "pass" "$module (healed)"
        return 0
    fi

    log_result "fail" "$module (heal failed)"
    return 1
}

run_module_break() {
    # Inject chaos for a single module (for testing).
    # Usage: run_module_break <module-name>

    local module=$1
    if ! is_module_registered "$module"; then
        log_error "self-heal: module '$module' is not registered"
        return 2
    fi

    [[ -z "$CHAOS_STATE_DIR" ]] && init_state_dir

    local break_fn
    break_fn="$(_fn "$module")_break"
    if ! declare -f "$break_fn" &>/dev/null; then
        log_error "self-heal: break function '$break_fn' not found for module '$module'"
        return 2
    fi

    log_action "self-heal: injecting chaos into '$module'"
    "$break_fn"
}

run_module_restore() {
    # Emergency restore a module from its snapshot.
    # Usage: run_module_restore <module-name>

    local module=$1
    if ! is_module_registered "$module"; then
        log_error "self-heal: module '$module' is not registered"
        return 2
    fi

    local restore_fn
    restore_fn="$(_fn "$module")_restore"
    if ! declare -f "$restore_fn" &>/dev/null; then
        log_error "self-heal: restore function '$restore_fn' not found for module '$module'"
        return 2
    fi

    log_action "self-heal: emergency restore of '$module'"
    "$restore_fn"
}

list_modules() {
    # Print all registered modules with their descriptions.

    if [[ ${#CHAOS_MODULES[@]} -eq 0 ]]; then
        log_warn "self-heal: no modules registered"
        return 0
    fi

    echo -e "${BOLD}Registered modules:${RESET}"
    local module describe_fn desc
    for module in "${CHAOS_MODULES[@]}"; do
        describe_fn="$(_fn "$module")_describe"
        if declare -f "$describe_fn" &>/dev/null; then
            desc="$("$describe_fn")"
        else
            desc="(no description)"
        fi
        printf "  ${CYAN}%-20s${RESET} %s\n" "$module" "$desc"
    done
}
