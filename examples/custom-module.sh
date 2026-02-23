#!/bin/bash
# custom-module.sh - Template for creating new chaos modules
# Copy this file to lib/modules/your-module.sh and customize

[[ -n "${_CHAOS_MOD_CUSTOM_LOADED:-}" ]] && return 0
_CHAOS_MOD_CUSTOM_LOADED=1

register_module "custom"

custom_describe() {
    echo "Custom module template - replace with your description"
}

custom_check() {
    # Return 0 if healthy, 1 if broken
    # Example: check if a service is responding
    # if curl -sf http://localhost:8080/health; then return 0; fi
    # return 1
    log_debug "custom_check: not implemented"
    return 0
}

custom_break() {
    if [[ "$CHAOS_DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would break custom service"
        return 0
    fi

    # 1. Save pre-break state
    # save_snapshot "custom" "state" "$(get_current_state)"

    # 2. Inject fault
    # docker stop my-service

    # 3. Verify broken
    # if custom_check; then log_error "Break failed"; return 1; fi

    log_action "Custom service broken"
    return 0
}

custom_heal() {
    # 1. Detect what's wrong
    # 2. Fix it
    # 3. Verify fixed
    # docker start my-service
    # sleep 5
    # if custom_check; then
    #     send_alert "Custom service healed" "info"
    #     return 0
    # fi

    log_warn "Custom heal: not implemented"
    return 1
}

custom_restore() {
    # Emergency restore from snapshot
    # local state=$(get_snapshot "custom" "state")
    # restore_to "$state"

    log_warn "Custom restore: not implemented"
    return 1
}
