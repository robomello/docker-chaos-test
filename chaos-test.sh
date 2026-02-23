#!/bin/bash
# chaos-test.sh - Docker chaos testing toolkit
# Injects faults into Docker infrastructure, measures recovery
#
# Usage:
#   ./chaos-test.sh [options]
#
# Options:
#   --rounds N          Number of test rounds (default: 1)
#   --modules LIST      Comma-separated module list (default: all)
#   --self-heal         Enable self-healing (no external watcher needed)
#   --restore           Emergency restore from last snapshot
#   --dry-run           Show what would happen without doing it
#   --list-modules      List available modules and exit
#   --config FILE       Load config file
#   --timeout N         Recovery timeout in seconds (default: 120)
#   --no-fleet          Skip fleet-wide container verification
#   --fleet-strategy S  Fleet heal strategy: "restart" or "report" (default: restart)
#   --verbose           Verbose output
#   -h, --help          Show help

set -uo pipefail

# ── Script Location ───────────────────────────────────────────────────
CHAOS_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Default Options ───────────────────────────────────────────────────
OPT_ROUNDS=1
OPT_MODULES=""       # empty = all
OPT_SELF_HEAL=false
OPT_RESTORE=false
OPT_DRY_RUN=false
OPT_LIST_MODULES=false
OPT_CONFIG=""
OPT_TIMEOUT=120
OPT_NO_FLEET=false
OPT_FLEET_STRATEGY=""
OPT_VERBOSE=false

# ── Argument Parsing ──────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --rounds N          Number of test rounds (default: 1)
  --modules LIST      Comma-separated module list (default: all)
  --self-heal         Enable self-healing (no external watcher needed)
  --restore           Emergency restore from last snapshot
  --dry-run           Show what would happen without doing it
  --list-modules      List available modules and exit
  --config FILE       Load config file
  --timeout N         Recovery timeout in seconds (default: 120)
  --no-fleet          Skip fleet-wide container verification
  --fleet-strategy S  Fleet heal strategy: "restart" or "report" (default: restart)
  --verbose           Verbose output
  -h, --help          Show help

Examples:
  $(basename "$0") --rounds 3 --modules dns,postgres --self-heal
  $(basename "$0") --dry-run --list-modules
  $(basename "$0") --restore --modules docker-socket
  $(basename "$0") --modules postgres --self-heal --fleet-strategy report
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rounds)
            [[ -z "${2:-}" ]] && { echo "ERROR: --rounds requires a value" >&2; exit 1; }
            OPT_ROUNDS="$2"
            shift 2
            ;;
        --modules)
            [[ -z "${2:-}" ]] && { echo "ERROR: --modules requires a value" >&2; exit 1; }
            OPT_MODULES="$2"
            shift 2
            ;;
        --self-heal)
            OPT_SELF_HEAL=true
            shift
            ;;
        --restore)
            OPT_RESTORE=true
            shift
            ;;
        --dry-run)
            OPT_DRY_RUN=true
            shift
            ;;
        --list-modules)
            OPT_LIST_MODULES=true
            shift
            ;;
        --config)
            [[ -z "${2:-}" ]] && { echo "ERROR: --config requires a value" >&2; exit 1; }
            OPT_CONFIG="$2"
            shift 2
            ;;
        --timeout)
            [[ -z "${2:-}" ]] && { echo "ERROR: --timeout requires a value" >&2; exit 1; }
            OPT_TIMEOUT="$2"
            shift 2
            ;;
        --no-fleet)
            OPT_NO_FLEET=true
            shift
            ;;
        --fleet-strategy)
            [[ -z "${2:-}" ]] && { echo "ERROR: --fleet-strategy requires a value" >&2; exit 1; }
            OPT_FLEET_STRATEGY="$2"
            shift 2
            ;;
        --verbose)
            OPT_VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# ── Validate Numeric Options ──────────────────────────────────────────
if ! [[ "$OPT_ROUNDS" =~ ^[0-9]+$ ]] || (( OPT_ROUNDS < 1 )); then
    echo "ERROR: --rounds must be a positive integer" >&2
    exit 1
fi

if ! [[ "$OPT_TIMEOUT" =~ ^[0-9]+$ ]] || (( OPT_TIMEOUT < 1 )); then
    echo "ERROR: --timeout must be a positive integer" >&2
    exit 1
fi

# Validate fleet strategy if given
if [[ -n "$OPT_FLEET_STRATEGY" ]] && [[ "$OPT_FLEET_STRATEGY" != "restart" ]] && [[ "$OPT_FLEET_STRATEGY" != "report" ]]; then
    echo "ERROR: --fleet-strategy must be 'restart' or 'report'" >&2
    exit 1
fi

# ── Export Options to Environment (picked up by common.sh defaults) ───
export CHAOS_VERBOSE="$OPT_VERBOSE"
export CHAOS_DRY_RUN="$OPT_DRY_RUN"

# ── Source Libraries ──────────────────────────────────────────────────
# self-heal.sh sources common.sh and all modules
if [[ ! -f "$CHAOS_TEST_DIR/lib/self-heal.sh" ]]; then
    echo "ERROR: Cannot find $CHAOS_TEST_DIR/lib/self-heal.sh" >&2
    exit 1
fi
# shellcheck source=lib/self-heal.sh
source "$CHAOS_TEST_DIR/lib/self-heal.sh"

# Initialize state directory (required for snapshots, cooldowns)
init_state_dir

# ── Load Config ───────────────────────────────────────────────────────
if [[ -n "$OPT_CONFIG" ]]; then
    load_config "$OPT_CONFIG" || exit 1
fi

# ── Apply CLI Overrides (CLI flags win over config file) ─────────────
if [[ "$OPT_VERBOSE" == "true" ]]; then
    CHAOS_VERBOSE="true"
fi
if [[ "$OPT_DRY_RUN" == "true" ]]; then
    CHAOS_DRY_RUN="true"
fi
if [[ -n "$OPT_FLEET_STRATEGY" ]]; then
    CHAOS_FLEET_STRATEGY="$OPT_FLEET_STRATEGY"
fi

# ── Prerequisites Check ───────────────────────────────────────────────
check_prerequisites || exit 1

# ── --list-modules ────────────────────────────────────────────────────
if [[ "$OPT_LIST_MODULES" == "true" ]]; then
    list_modules
    cleanup_state_dir
    exit 0
fi

# ── Resolve Module List ───────────────────────────────────────────────
resolve_modules() {
    local selected=()

    if [[ -z "$OPT_MODULES" ]]; then
        # Default: all registered modules
        selected=("${CHAOS_MODULES[@]}")
    else
        # Parse comma-separated list
        IFS=',' read -ra requested <<< "$OPT_MODULES"
        for mod in "${requested[@]}"; do
            mod="${mod// /}"  # trim spaces
            if is_module_registered "$mod"; then
                selected+=("$mod")
            else
                log_error "Unknown module: '$mod'. Use --list-modules to see available modules."
                cleanup_state_dir
                exit 1
            fi
        done
    fi

    if [[ ${#selected[@]} -eq 0 ]]; then
        log_error "No modules available. Use --list-modules to check."
        cleanup_state_dir
        exit 1
    fi

    echo "${selected[@]}"
}

# shellcheck disable=SC2207
SELECTED_MODULES=($(resolve_modules)) || exit 1

# ── --restore ─────────────────────────────────────────────────────────
if [[ "$OPT_RESTORE" == "true" ]]; then
    echo -e "${BOLD}${YELLOW}Emergency Restore${RESET}"
    echo ""
    local_fail=0
    for module in "${SELECTED_MODULES[@]}"; do
        log_action "Restoring: $module"
        run_module_restore "$module" || (( local_fail++ )) || true
    done
    cleanup_state_dir
    if (( local_fail > 0 )); then
        log_error "Restore completed with $local_fail failure(s)"
        exit 1
    fi
    log_info "Restore complete"
    exit 0
fi

# ── Module Name Normalizer ────────────────────────────────────────────
module_fn() {
    echo "${1//-/_}"
}

# ── Confirmation Prompt ───────────────────────────────────────────────
show_confirmation() {
    local self_heal_label="no"
    [[ "$OPT_SELF_HEAL" == "true" ]] && self_heal_label="yes"
    [[ "$OPT_DRY_RUN" == "true" ]] && self_heal_label="${self_heal_label} (dry-run)"

    local mod_list
    mod_list="${SELECTED_MODULES[*]}"
    mod_list="${mod_list// /, }"

    echo ""
    echo -e "${BOLD}Chaos Test Configuration:${RESET}"
    printf "  Rounds:    %s\n" "$OPT_ROUNDS"
    printf "  Modules:   %s\n" "$mod_list"
    printf "  Self-heal: %s\n" "$self_heal_label"
    printf "  Timeout:   %ss\n" "$OPT_TIMEOUT"
    if [[ "$OPT_NO_FLEET" == "true" ]]; then
        printf "  Fleet:     %s\n" "disabled"
    else
        printf "  Fleet:     %s\n" "enabled (strategy: $CHAOS_FLEET_STRATEGY)"
    fi
    echo ""

    if [[ "$OPT_DRY_RUN" == "true" ]]; then
        echo -e "${DIM}Dry-run mode: no changes will be made.${RESET}"
        echo ""
        return 0
    fi

    echo -e "${YELLOW}This will inject faults into your system. Continue? [y/N]${RESET} "
    read -r answer
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *)
            echo "Aborted."
            cleanup_state_dir
            exit 0
            ;;
    esac
}

show_confirmation

# ── Per-Module Tracking ───────────────────────────────────────────────
# Associative arrays: module -> running totals
declare -A MOD_PASS      # passes across all rounds
declare -A MOD_FAIL      # fails across all rounds
declare -A MOD_TOTAL_SEC # total recovery seconds (for avg)
declare -A MOD_HEAL_CNT  # count of rounds where recovery time is known

for module in "${SELECTED_MODULES[@]}"; do
    MOD_PASS["$module"]=0
    MOD_FAIL["$module"]=0
    MOD_TOTAL_SEC["$module"]=0
    MOD_HEAL_CNT["$module"]=0
done

# ── Fleet Tracking Across Rounds ─────────────────────────────────────
FLEET_ROUND_PASS=0
FLEET_ROUND_FAIL=0
FLEET_TOTAL_DAMAGED=0
FLEET_TOTAL_RESTARTED=0
FLEET_TOTAL_STILL_BROKEN=0

# ── Trap Handler ──────────────────────────────────────────────────────
# Track which modules are currently broken for cleanup
declare -a CURRENTLY_BROKEN=()

_trap_cleanup() {
    echo ""
    log_warn "Interrupted! Restoring all broken modules..."
    for module in "${CURRENTLY_BROKEN[@]:-}"; do
        log_action "Emergency restore: $module"
        local restore_fn
        restore_fn="$( module_fn "$module" )_restore"
        if declare -f "$restore_fn" &>/dev/null; then
            "$restore_fn" || log_error "Restore failed for $module"
        else
            log_warn "No restore function for $module"
        fi
    done
    cleanup_state_dir
    exit 130
}

trap '_trap_cleanup' SIGINT SIGTERM

# ── Poll for Recovery ─────────────────────────────────────────────────
# Returns 0 if all modules recovered within timeout.
# Populates ROUND_RECOVERY_SEC[module] and ROUND_STATUS[module].
poll_recovery() {
    local -n _broken_ref=$1    # nameref to array of broken module names
    local -n _rec_sec_ref=$2   # nameref to assoc array: module -> recovery seconds
    local -n _status_ref=$3    # nameref to assoc array: module -> PASS/FAIL
    local timeout=$4

    # Initialize status
    for module in "${_broken_ref[@]}"; do
        _status_ref["$module"]="pending"
        _rec_sec_ref["$module"]=""
    done

    local start_ts
    start_ts=$(date +%s)
    local elapsed=0

    while (( elapsed < timeout )); do
        local all_done=true

        for module in "${_broken_ref[@]}"; do
            [[ "${_status_ref[$module]}" != "pending" ]] && continue

            # Optionally trigger self-heal before checking
            if [[ "$OPT_SELF_HEAL" == "true" ]]; then
                local heal_fn
                heal_fn="$( module_fn "$module" )_heal"
                if declare -f "$heal_fn" &>/dev/null; then
                    "$heal_fn" &>/dev/null || true
                fi
            fi

            local check_fn
            check_fn="$( module_fn "$module" )_check"
            if declare -f "$check_fn" &>/dev/null && "$check_fn" &>/dev/null 2>&1; then
                local now
                now=$(date +%s)
                _rec_sec_ref["$module"]=$(( now - start_ts ))
                _status_ref["$module"]="PASS"
                log_debug "poll_recovery: $module recovered in ${_rec_sec_ref[$module]}s"
            else
                all_done=false
            fi
        done

        "$all_done" && break

        sleep 2
        elapsed=$(( $(date +%s) - start_ts ))
    done

    # Mark anything still pending as FAIL (timeout)
    for module in "${_broken_ref[@]}"; do
        if [[ "${_status_ref[$module]}" == "pending" ]]; then
            _status_ref["$module"]="FAIL"
            _rec_sec_ref["$module"]=""
        fi
    done
}

# ── Print Round Results Table ─────────────────────────────────────────
print_round_table() {
    local round=$1
    local total_rounds=$2
    local -n _rstatus=$3   # assoc: module -> PASS/FAIL
    local -n _rsec=$4      # assoc: module -> seconds or ""

    echo ""
    echo -e "${BOLD}Round ${round}/${total_rounds} Results:${RESET}"
    printf "  %-20s %-10s %s\n" "Module" "Status" "Recovery"
    printf "  %-20s %-10s %s\n" "------" "------" "--------"

    for module in "${SELECTED_MODULES[@]}"; do
        local status="${_rstatus[$module]:-SKIP}"
        local recovery=""
        local status_color="${RESET}"

        if [[ "$status" == "PASS" ]]; then
            status_color="${GREEN}"
            local secs="${_rsec[$module]:-}"
            if [[ -n "$secs" ]]; then
                recovery="$( format_duration "$secs" )"
            else
                recovery="immediate"
            fi
        elif [[ "$status" == "FAIL" ]]; then
            status_color="${RED}"
            recovery="timeout (${OPT_TIMEOUT}s)"
        elif [[ "$status" == "SKIP" ]]; then
            status_color="${DIM}"
            recovery="(skipped - already broken)"
        fi

        printf "  %-20s ${status_color}%-10s${RESET} %s\n" \
            "$module" "$status" "$recovery"
    done
    echo ""
}

# ── Fleet Initialization ──────────────────────────────────────────────
if [[ "$OPT_NO_FLEET" != "true" ]]; then
    fleet_init
    fleet_snapshot
fi

# ── Main Round Loop ───────────────────────────────────────────────────
TOTAL_PASS=0
TOTAL_FAIL=0

for (( round = 1; round <= OPT_ROUNDS; round++ )); do
    echo ""
    echo -e "${BOLD}${BLUE}══════════════════════════════${RESET}"
    echo -e "${BOLD}${BLUE}  Round ${round}/${OPT_ROUNDS}${RESET}"
    echo -e "${BOLD}${BLUE}══════════════════════════════${RESET}"

    declare -a broken_this_round=()
    declare -A break_ts=()

    # ── (a) Baseline check ALL modules first, before breaking any ─────
    declare -a breakable_modules=()
    for module in "${SELECTED_MODULES[@]}"; do
        check_fn="$( module_fn "$module" )_check"
        break_fn="$( module_fn "$module" )_break"

        # Skip read-only modules (break returns 1 by design)
        if declare -f "$break_fn" &>/dev/null; then
            # Test if break function is a stub that always fails (read-only)
            break_body=$(declare -f "$break_fn")
            if echo "$break_body" | grep -q "read-only"; then
                log_debug "Round $round: $module is read-only, skipping"
                continue
            fi
        else
            log_error "Round $round: no break function found for $module"
            continue
        fi

        # Verify healthy baseline
        if declare -f "$check_fn" &>/dev/null; then
            if ! "$check_fn" &>/dev/null 2>&1; then
                log_warn "Round $round: $module is already unhealthy, skipping break"
                continue
            fi
        fi

        breakable_modules+=("$module")
    done

    # ── (a2) Break all verified-healthy modules ───────────────────────
    # Sort: docker-socket last since it kills Docker access for other modules
    declare -a ordered_breakable=()
    docker_socket_deferred=""
    for module in "${breakable_modules[@]}"; do
        if [[ "$module" == "docker-socket" ]]; then
            docker_socket_deferred="docker-socket"
        else
            ordered_breakable+=("$module")
        fi
    done
    [[ -n "$docker_socket_deferred" ]] && ordered_breakable+=("docker-socket")

    for module in "${ordered_breakable[@]}"; do
        break_fn="$( module_fn "$module" )_break"
        log_action "Round $round: breaking $module"
        if "$break_fn"; then
            broken_this_round+=("$module")
            break_ts["$module"]=$(date +%s)
            CURRENTLY_BROKEN+=("$module")
        else
            log_error "Round $round: break function failed for $module"
        fi
    done

    if [[ ${#broken_this_round[@]} -eq 0 ]]; then
        log_warn "Round $round: no modules were broken, skipping recovery poll"
        continue
    fi

    # ── (b) Poll for recovery ─────────────────────────────────────────
    log_info "Round $round: waiting for recovery (timeout: ${OPT_TIMEOUT}s)..."
    declare -A round_status=()
    declare -A round_rec_sec=()

    poll_recovery broken_this_round round_rec_sec round_status "$OPT_TIMEOUT"

    # ── Remove recovered modules from CURRENTLY_BROKEN ───────────────
    new_broken=()
    for m in "${CURRENTLY_BROKEN[@]}"; do
        is_still_broken=false
        for bm in "${broken_this_round[@]}"; do
            if [[ "$m" == "$bm" ]] && [[ "${round_status[$m]:-}" == "FAIL" ]]; then
                is_still_broken=true
                break
            fi
        done
        "$is_still_broken" && new_broken+=("$m") || true
    done
    CURRENTLY_BROKEN=("${new_broken[@]:-}")

    # ── (c) Accumulate per-module stats ──────────────────────────────
    for module in "${broken_this_round[@]}"; do
        st="${round_status[$module]:-FAIL}"
        if [[ "$st" == "PASS" ]]; then
            MOD_PASS["$module"]=$(( ${MOD_PASS[$module]} + 1 ))
            (( TOTAL_PASS++ ))
            secs="${round_rec_sec[$module]:-0}"
            MOD_TOTAL_SEC["$module"]=$(( ${MOD_TOTAL_SEC[$module]} + secs ))
            MOD_HEAL_CNT["$module"]=$(( ${MOD_HEAL_CNT[$module]} + 1 ))
        else
            MOD_FAIL["$module"]=$(( ${MOD_FAIL[$module]} + 1 ))
            (( TOTAL_FAIL++ ))
        fi
    done

    # ── (d) Add SKIP for modules not broken this round ────────────────
    for module in "${SELECTED_MODULES[@]}"; do
        found=false
        for bm in "${broken_this_round[@]}"; do
            [[ "$module" == "$bm" ]] && { found=true; break; }
        done
        if ! "$found"; then
            round_status["$module"]="SKIP"
            round_rec_sec["$module"]=""
        fi
    done

    # ── (e) Fleet verification ───────────────────────────────────────
    if [[ "$OPT_NO_FLEET" != "true" ]]; then
        fleet_reset

        # Compute blast radius from broken modules
        fleet_compute_blast_radius "${broken_this_round[@]}"

        log_info "Round $round: verifying fleet health..."
        if ! fleet_verify; then
            log_warn "Round $round: collateral damage - ${#FLEET_DAMAGED[@]} containers affected"
            FLEET_TOTAL_DAMAGED=$(( FLEET_TOTAL_DAMAGED + ${#FLEET_DAMAGED[@]} ))

            if [[ "$OPT_SELF_HEAL" == "true" ]]; then
                fleet_heal
            fi

            FLEET_TOTAL_RESTARTED=$(( FLEET_TOTAL_RESTARTED + ${#FLEET_RESTARTED[@]} ))
            FLEET_TOTAL_STILL_BROKEN=$(( FLEET_TOTAL_STILL_BROKEN + ${#FLEET_STILL_BROKEN[@]} ))

            if [[ ${#FLEET_STILL_BROKEN[@]} -gt 0 ]]; then
                (( FLEET_ROUND_FAIL++ ))
            else
                (( FLEET_ROUND_PASS++ ))
            fi
        else
            log_info "Round $round: fleet healthy - no collateral damage"
            (( FLEET_ROUND_PASS++ ))
        fi
    fi

    # ── (f) Print round table ─────────────────────────────────────────
    print_round_table "$round" "$OPT_ROUNDS" round_status round_rec_sec

    # Fleet report for this round
    if [[ "$OPT_NO_FLEET" != "true" ]]; then
        fleet_report
    fi

    # Clean up per-round arrays to avoid bleed-through
    unset broken_this_round break_ts round_status round_rec_sec
    declare -a broken_this_round=()
    # shellcheck disable=SC2034  # break_ts is used in the next iteration
    declare -A break_ts=()
    declare -A round_status=()
    declare -A round_rec_sec=()
done

# ── Final Summary ─────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}═══ Final Summary ═══${RESET}"
printf "  %-20s %-6s %-6s %s\n" "Module" "Pass" "Fail" "Avg Recovery"
printf "  %-20s %-6s %-6s %s\n" "------" "----" "----" "------------"

for module in "${SELECTED_MODULES[@]}"; do
    _s_pass="${MOD_PASS[$module]:-0}"
    _s_fail="${MOD_FAIL[$module]:-0}"
    _s_total=$(( _s_pass + _s_fail ))
    _s_avg_str="-"

    if (( ${MOD_HEAL_CNT[$module]:-0} > 0 )); then
        _s_avg_sec=$(( MOD_TOTAL_SEC[$module] / MOD_HEAL_CNT[$module] ))
        _s_avg_str="$( format_duration "$_s_avg_sec" )"
    elif (( _s_total == 0 )); then
        _s_avg_str="(skipped)"
    fi

    _s_pass_color="${RESET}"
    _s_fail_color="${RESET}"
    (( _s_pass > 0 )) && _s_pass_color="${GREEN}"
    (( _s_fail > 0 )) && _s_fail_color="${RED}"

    printf "  %-20s ${_s_pass_color}%-6s${RESET} ${_s_fail_color}%-6s${RESET} %s\n" \
        "$module" \
        "${_s_pass}/${_s_total}" \
        "${_s_fail}/${_s_total}" \
        "$_s_avg_str"
done

# Fleet summary across rounds
if [[ "$OPT_NO_FLEET" != "true" ]]; then
    echo ""
    echo -e "  ${BOLD}Fleet Health:${RESET}"
    _fleet_rounds_total=$(( FLEET_ROUND_PASS + FLEET_ROUND_FAIL ))
    if (( _fleet_rounds_total > 0 )); then
        printf "    %s damaged, %s recovered, %s still broken across %s round(s) (%s containers)\n" \
            "$FLEET_TOTAL_DAMAGED" "$FLEET_TOTAL_RESTARTED" "$FLEET_TOTAL_STILL_BROKEN" \
            "$_fleet_rounds_total" "${#FLEET_CONTAINERS[@]}"
        if (( FLEET_ROUND_FAIL > 0 )); then
            echo -e "    Fleet: ${RED}${BOLD}${FLEET_ROUND_PASS}/${_fleet_rounds_total} rounds passed${RESET}"
        else
            echo -e "    Fleet: ${GREEN}${BOLD}${FLEET_ROUND_PASS}/${_fleet_rounds_total} rounds passed${RESET}"
        fi
    else
        echo -e "    ${DIM}No fleet checks ran${RESET}"
    fi
fi

echo ""
GRAND_TOTAL=$(( TOTAL_PASS + TOTAL_FAIL ))
_fleet_rounds_final=$(( FLEET_ROUND_PASS + FLEET_ROUND_FAIL ))
_fleet_str=""
if [[ "$OPT_NO_FLEET" != "true" ]] && (( _fleet_rounds_final > 0 )); then
    _fleet_str=", fleet ${FLEET_ROUND_PASS}/${_fleet_rounds_final} passed"
fi

if (( GRAND_TOTAL > 0 )); then
    PCT=$(( TOTAL_PASS * 100 / GRAND_TOTAL ))
    if (( PCT == 100 )) && (( FLEET_ROUND_FAIL == 0 )); then
        echo -e "  Overall: ${GREEN}${BOLD}${TOTAL_PASS}/${GRAND_TOTAL} modules passed${_fleet_str} (${PCT}%)${RESET}"
    elif (( PCT >= 80 )); then
        echo -e "  Overall: ${YELLOW}${BOLD}${TOTAL_PASS}/${GRAND_TOTAL} modules passed${_fleet_str} (${PCT}%)${RESET}"
    else
        echo -e "  Overall: ${RED}${BOLD}${TOTAL_PASS}/${GRAND_TOTAL} modules passed${_fleet_str} (${PCT}%)${RESET}"
    fi
else
    echo -e "  Overall: ${DIM}No modules tested${RESET}"
fi
echo ""

cleanup_state_dir

# Fail if any module failed OR fleet had unrecoverable damage
if (( TOTAL_FAIL > 0 )) || (( FLEET_TOTAL_STILL_BROKEN > 0 )); then
    exit 1
fi
exit 0
