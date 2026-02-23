#!/bin/bash
# fleet.sh - Fleet-wide steady-state verification
# Snapshots all running containers before chaos, verifies after recovery,
# restarts collateral damage, and reports results.
#
# Inspired by LitmusChaos SoT/EoT probes and Gremlin blast radius.

[[ -n "${_CHAOS_FLEET_LOADED:-}" ]] && return 0
_CHAOS_FLEET_LOADED=1

# ── Fleet Service Registry ───────────────────────────────────────────
declare -A FLEET_HEALTH_URL=()    # container -> health URL (or empty)
declare -A FLEET_DEPENDS_ON=()    # container -> "dep1,dep2" comma-separated
declare -A FLEET_TIMEOUT=()       # container -> recovery timeout in seconds
declare -a FLEET_CONTAINERS=()    # ordered list of all tracked containers
declare -A FLEET_CONFIGURED=()    # containers explicitly in CHAOS_FLEET_SERVICES

# ── Steady State Snapshot ────────────────────────────────────────────
declare -A STEADY_RUNNING=()      # container -> "true"/"false" at snapshot time
declare -A STEADY_HEALTHY=()      # container -> "true"/"false" (health URL result)

# ── Blast Radius Zones ────────────────────────────────────────────────
declare -a BLAST_ZONE_0=()        # primary: intentionally broken (module containers)
declare -a BLAST_ZONE_1=()        # immediate: direct dependents of zone 0
declare -a BLAST_ZONE_2=()        # secondary: transitive dependents of zone 1

# ── Recovery Tracking ────────────────────────────────────────────────
declare -A FLEET_STATUS=()        # container -> HEALTHY/DAMAGED/RESTARTED/FAILED
declare -A FLEET_RECOVERY_SEC=()  # container -> seconds to recover (or empty)
declare -A FLEET_DAMAGE_REASON=() # container -> "not-running"/"health-timeout"/""
declare -a FLEET_DAMAGED=()       # containers found damaged
declare -a FLEET_RESTARTED=()     # containers we restarted successfully
declare -a FLEET_STILL_BROKEN=()  # containers still broken after heal

# ── fleet_init ───────────────────────────────────────────────────────
# Parse CHAOS_FLEET_SERVICES into associative arrays. Auto-discover
# additional containers from docker ps that aren't in the config.
fleet_init() {
    FLEET_CONTAINERS=()
    FLEET_HEALTH_URL=()
    FLEET_DEPENDS_ON=()
    FLEET_TIMEOUT=()
    FLEET_CONFIGURED=()

    # Parse configured services: "container|health_url|depends_on|timeout"
    if [[ -n "${CHAOS_FLEET_SERVICES+x}" ]] && [[ ${#CHAOS_FLEET_SERVICES[@]} -gt 0 ]]; then
        for entry in "${CHAOS_FLEET_SERVICES[@]}"; do
            local name health_url depends timeout
            IFS='|' read -r name health_url depends timeout <<< "$entry"
            name="${name## }"; name="${name%% }"
            [[ -z "$name" ]] && continue

            FLEET_CONTAINERS+=("$name")
            FLEET_CONFIGURED["$name"]=1
            FLEET_HEALTH_URL["$name"]="${health_url:-}"
            FLEET_DEPENDS_ON["$name"]="${depends:-}"
            FLEET_TIMEOUT["$name"]="${timeout:-$CHAOS_FLEET_TIMEOUT}"
        done
    fi

    # Auto-discover running containers not in config
    local running
    running=$(docker ps --format '{{.Names}}' 2>/dev/null) || return 1

    while IFS= read -r cname; do
        [[ -z "$cname" ]] && continue

        # Skip containers matching CHAOS_FLEET_SKIP
        if [[ -n "${CHAOS_FLEET_SKIP:-}" ]] && echo "$cname" | grep -qE "$CHAOS_FLEET_SKIP"; then
            log_debug "fleet_init: skipping $cname (matches CHAOS_FLEET_SKIP)"
            continue
        fi

        # Skip if already configured
        if [[ -n "${FLEET_CONFIGURED[$cname]+x}" ]]; then
            continue
        fi

        FLEET_CONTAINERS+=("$cname")
        FLEET_HEALTH_URL["$cname"]=""
        FLEET_DEPENDS_ON["$cname"]=""
        FLEET_TIMEOUT["$cname"]="$CHAOS_FLEET_TIMEOUT"
    done <<< "$running"

    log_debug "fleet_init: ${#FLEET_CONTAINERS[@]} containers tracked (${#FLEET_CONFIGURED[@]} configured)"
}

# ── fleet_snapshot ───────────────────────────────────────────────────
# Record steady state of all tracked containers before chaos begins.
# Prints container count. Creates $CHAOS_STATE_DIR/fleet/ for state files.
fleet_snapshot() {
    STEADY_RUNNING=()
    STEADY_HEALTHY=()

    mkdir -p "$CHAOS_STATE_DIR/fleet"

    local count=0
    local health_count=0

    for cname in "${FLEET_CONTAINERS[@]}"; do
        # Check running status
        if is_container_running "$cname"; then
            STEADY_RUNNING["$cname"]="true"
        else
            STEADY_RUNNING["$cname"]="false"
            log_debug "fleet_snapshot: $cname not running at baseline"
        fi

        # Check health URL if configured
        local url="${FLEET_HEALTH_URL[$cname]:-}"
        if [[ -n "$url" ]] && [[ "${STEADY_RUNNING[$cname]}" == "true" ]]; then
            if curl -sf --max-time 5 "$url" >/dev/null 2>&1; then
                STEADY_HEALTHY["$cname"]="true"
            else
                STEADY_HEALTHY["$cname"]="false"
                log_debug "fleet_snapshot: $cname health URL failed at baseline ($url)"
            fi
            (( health_count++ ))
        fi

        (( count++ ))
    done

    # Persist snapshot to state dir for debugging
    printf '%s\n' "${!STEADY_RUNNING[@]}" > "$CHAOS_STATE_DIR/fleet/snapshot_containers"
    for cname in "${!STEADY_RUNNING[@]}"; do
        echo "${cname}:${STEADY_RUNNING[$cname]}:${STEADY_HEALTHY[$cname]:-}" >> "$CHAOS_STATE_DIR/fleet/snapshot_state"
    done

    log_info "Fleet snapshot: $count containers ($health_count with health URLs)"
}

# ── fleet_compute_blast_radius ────────────────────────────────────────
# Given a list of broken module names, compute which containers fall
# into each blast zone. Uses CHAOS_MODULE_CONTAINERS_<module> mappings
# and the dependency graph from FLEET_DEPENDS_ON.
# Args: module names (space-separated)
fleet_compute_blast_radius() {
    BLAST_ZONE_0=()
    BLAST_ZONE_1=()
    BLAST_ZONE_2=()

    local -A zone0_set=()
    local -A zone1_set=()
    local -A zone2_set=()

    # Build zone 0: containers directly broken by each module
    for module in "$@"; do
        local varname="CHAOS_MODULE_CONTAINERS_${module//-/_}"
        local containers="${!varname:-}"

        if [[ -z "$containers" ]]; then
            # Special modules (docker-socket, dns, disk-space) affect the host,
            # not specific containers. Skip zone mapping for these.
            log_debug "blast_radius: $module has no container mapping, skipping zone 0"
            continue
        fi

        IFS=',' read -ra clist <<< "$containers"
        for c in "${clist[@]}"; do
            c="${c## }"; c="${c%% }"
            [[ -z "$c" ]] && continue
            zone0_set["$c"]=1
        done
    done

    # Build zone 1: containers whose depends_on includes any zone 0 container
    for cname in "${FLEET_CONTAINERS[@]}"; do
        [[ -n "${zone0_set[$cname]+x}" ]] && continue
        local deps="${FLEET_DEPENDS_ON[$cname]:-}"
        [[ -z "$deps" ]] && continue

        IFS=',' read -ra dep_arr <<< "$deps"
        for d in "${dep_arr[@]}"; do
            d="${d## }"; d="${d%% }"
            if [[ -n "${zone0_set[$d]+x}" ]]; then
                zone1_set["$cname"]=1
                break
            fi
        done
    done

    # Build zone 2: containers whose depends_on includes any zone 1 container
    for cname in "${FLEET_CONTAINERS[@]}"; do
        [[ -n "${zone0_set[$cname]+x}" ]] && continue
        [[ -n "${zone1_set[$cname]+x}" ]] && continue
        local deps="${FLEET_DEPENDS_ON[$cname]:-}"
        [[ -z "$deps" ]] && continue

        IFS=',' read -ra dep_arr <<< "$deps"
        for d in "${dep_arr[@]}"; do
            d="${d## }"; d="${d%% }"
            if [[ -n "${zone1_set[$d]+x}" ]]; then
                zone2_set["$cname"]=1
                break
            fi
        done
    done

    # Convert sets to arrays
    for c in "${!zone0_set[@]}"; do BLAST_ZONE_0+=("$c"); done
    for c in "${!zone1_set[@]}"; do BLAST_ZONE_1+=("$c"); done
    for c in "${!zone2_set[@]}"; do BLAST_ZONE_2+=("$c"); done

    log_debug "blast_radius: zone0=${#BLAST_ZONE_0[@]} zone1=${#BLAST_ZONE_1[@]} zone2=${#BLAST_ZONE_2[@]}"
}

# ── fleet_verify ─────────────────────────────────────────────────────
# Compare current state against steady-state snapshot. Populates
# FLEET_STATUS, FLEET_DAMAGE_REASON, FLEET_DAMAGED.
# Returns: 0 if all healthy, 1 if any damaged.
fleet_verify() {
    FLEET_STATUS=()
    FLEET_DAMAGE_REASON=()
    FLEET_DAMAGED=()

    for cname in "${FLEET_CONTAINERS[@]}"; do
        # Only check containers that were running at snapshot time
        if [[ "${STEADY_RUNNING[$cname]:-false}" != "true" ]]; then
            FLEET_STATUS["$cname"]="SKIP"
            continue
        fi

        # Check if still running
        if ! is_container_running "$cname"; then
            FLEET_STATUS["$cname"]="DAMAGED"
            FLEET_DAMAGE_REASON["$cname"]="not-running"
            FLEET_DAMAGED+=("$cname")
            log_debug "fleet_verify: $cname not running"
            continue
        fi

        # Check health URL if configured and was healthy at baseline
        local url="${FLEET_HEALTH_URL[$cname]:-}"
        if [[ -n "$url" ]] && [[ "${STEADY_HEALTHY[$cname]:-}" == "true" ]]; then
            if ! curl -sf --max-time 5 "$url" >/dev/null 2>&1; then
                FLEET_STATUS["$cname"]="DAMAGED"
                FLEET_DAMAGE_REASON["$cname"]="health-timeout"
                FLEET_DAMAGED+=("$cname")
                log_debug "fleet_verify: $cname health check failed ($url)"
                continue
            fi
        fi

        FLEET_STATUS["$cname"]="HEALTHY"
        FLEET_DAMAGE_REASON["$cname"]=""
    done

    if [[ ${#FLEET_DAMAGED[@]} -gt 0 ]]; then
        return 1
    fi
    return 0
}

# ── _fleet_dep_order ─────────────────────────────────────────────────
# Sort containers so parents come before children (dependency order).
# Reads FLEET_DEPENDS_ON. Outputs sorted list on stdout.
_fleet_dep_order() {
    local -a input=("$@")
    local -A in_set=()
    for c in "${input[@]}"; do in_set["$c"]=1; done

    # Simple topological sort: containers with no deps in list go first
    local -a sorted=()
    local -A placed=()
    local max_iter=${#input[@]}
    local iter=0

    while [[ ${#sorted[@]} -lt ${#input[@]} ]] && (( iter < max_iter * 2 )); do
        for c in "${input[@]}"; do
            [[ -n "${placed[$c]+x}" ]] && continue

            # Check if all deps that are in our set are already placed
            local deps="${FLEET_DEPENDS_ON[$c]:-}"
            local blocked=false
            if [[ -n "$deps" ]]; then
                IFS=',' read -ra dep_arr <<< "$deps"
                for d in "${dep_arr[@]}"; do
                    d="${d## }"; d="${d%% }"
                    if [[ -n "${in_set[$d]+x}" ]] && [[ -z "${placed[$d]+x}" ]]; then
                        blocked=true
                        break
                    fi
                done
            fi

            if ! "$blocked"; then
                sorted+=("$c")
                placed["$c"]=1
            fi
        done
        (( iter++ ))
    done

    # Add any remaining (circular deps) at the end
    for c in "${input[@]}"; do
        [[ -z "${placed[$c]+x}" ]] && sorted+=("$c")
    done

    printf '%s\n' "${sorted[@]}"
}

# ── fleet_heal ───────────────────────────────────────────────────────
# Restart damaged containers in dependency order, poll for recovery.
# Returns: 0 if all recovered, 1 if any still broken.
fleet_heal() {
    FLEET_RESTARTED=()
    FLEET_STILL_BROKEN=()
    FLEET_RECOVERY_SEC=()

    if [[ "$CHAOS_FLEET_STRATEGY" == "report" ]]; then
        log_info "Fleet strategy: report-only, skipping restart"
        FLEET_STILL_BROKEN=("${FLEET_DAMAGED[@]}")
        return 1
    fi

    if [[ ${#FLEET_DAMAGED[@]} -eq 0 ]]; then
        return 0
    fi

    # Sort by dependency order (parents first)
    local -a ordered=()
    while IFS= read -r c; do
        [[ -n "$c" ]] && ordered+=("$c")
    done < <(_fleet_dep_order "${FLEET_DAMAGED[@]}")

    log_info "Fleet heal: restarting ${#ordered[@]} containers in dependency order"

    for cname in "${ordered[@]}"; do
        local timeout="${FLEET_TIMEOUT[$cname]:-$CHAOS_FLEET_TIMEOUT}"
        local url="${FLEET_HEALTH_URL[$cname]:-}"

        if [[ "$CHAOS_DRY_RUN" == "true" ]]; then
            log_action "[DRY RUN] would restart $cname (timeout: ${timeout}s)"
            FLEET_RESTARTED+=("$cname")
            FLEET_STATUS["$cname"]="RESTARTED"
            FLEET_RECOVERY_SEC["$cname"]="0"
            continue
        fi

        log_action "Fleet heal: restarting $cname"
        local heal_start
        heal_start=$(date +%s)
        docker restart "$cname" >/dev/null 2>&1

        # Poll for recovery
        local elapsed=0
        local recovered=false

        while (( elapsed < timeout )); do
            sleep 2
            elapsed=$(( elapsed + 2 ))

            if ! is_container_running "$cname"; then
                continue
            fi

            # If no health URL, running is enough
            if [[ -z "$url" ]]; then
                recovered=true
                break
            fi

            # Check health URL
            if curl -sf --max-time 5 "$url" >/dev/null 2>&1; then
                recovered=true
                break
            fi
        done

        local heal_elapsed=$(( $(date +%s) - heal_start ))

        if "$recovered"; then
            FLEET_RESTARTED+=("$cname")
            FLEET_STATUS["$cname"]="RESTARTED"
            FLEET_RECOVERY_SEC["$cname"]="$heal_elapsed"
            log_info "Fleet heal: $cname recovered in ${heal_elapsed}s"
        else
            FLEET_STILL_BROKEN+=("$cname")
            FLEET_STATUS["$cname"]="FAILED"
            FLEET_RECOVERY_SEC["$cname"]=""
            log_error "Fleet heal: $cname still broken after ${timeout}s"
        fi
    done

    if [[ ${#FLEET_STILL_BROKEN[@]} -gt 0 ]]; then
        return 1
    fi
    return 0
}

# ── _fleet_container_zone ─────────────────────────────────────────────
# Return which blast zone a container belongs to (0, 1, 2, or "-").
_fleet_container_zone() {
    local cname=$1
    for c in "${BLAST_ZONE_0[@]:-}"; do [[ "$c" == "$cname" ]] && { echo "0"; return; }; done
    for c in "${BLAST_ZONE_1[@]:-}"; do [[ "$c" == "$cname" ]] && { echo "1"; return; }; done
    for c in "${BLAST_ZONE_2[@]:-}"; do [[ "$c" == "$cname" ]] && { echo "2"; return; }; done
    echo "-"
}

# ── _fleet_print_zone_row ────────────────────────────────────────────
# Print a single container row with status, recovery time, and reason.
_fleet_print_zone_row() {
    local cname=$1
    local status="${FLEET_STATUS[$cname]:-HEALTHY}"
    local reason="${FLEET_DAMAGE_REASON[$cname]:-}"
    local rec_sec="${FLEET_RECOVERY_SEC[$cname]:-}"
    local status_color="${RESET}"
    local rec_str="-"
    local detail=""

    case "$status" in
        HEALTHY)   status_color="${GREEN}" ;;
        RESTARTED) status_color="${YELLOW}" ;;
        FAILED)    status_color="${RED}" ;;
        DAMAGED)   status_color="${RED}" ;;
        SKIP)      status_color="${DIM}" ;;
    esac

    if [[ -n "$rec_sec" ]]; then
        rec_str="${rec_sec}s"
    fi

    if [[ -n "$reason" ]] && [[ "$status" != "HEALTHY" ]]; then
        if [[ "$status" == "RESTARTED" ]]; then
            detail="(${reason} -> docker restart)"
        elif [[ "$status" == "HEALTHY" ]]; then
            detail="(auto-reconnected)"
        else
            detail="(${reason})"
        fi
    elif [[ "$status" == "HEALTHY" ]] && [[ "$(_fleet_container_zone "$cname")" != "-" ]]; then
        detail="(auto-reconnected)"
    fi

    printf "      %-22s ${status_color}%-12s${RESET} %-6s %s\n" \
        "$cname" "$status" "$rec_str" "$detail"
}

# ── fleet_report ─────────────────────────────────────────────────────
# Print zone-based fleet health summary.
fleet_report() {
    local total=${#FLEET_CONTAINERS[@]}
    local damaged=${#FLEET_DAMAGED[@]}
    local restarted=${#FLEET_RESTARTED[@]}
    local still_broken=${#FLEET_STILL_BROKEN[@]}

    echo ""
    echo -e "  ${BOLD}Fleet Health (${total} containers):${RESET}"

    if [[ $damaged -eq 0 ]] && [[ ${#BLAST_ZONE_0[@]} -eq 0 ]]; then
        echo -e "    ${GREEN}All containers healthy${RESET}"
    else
        local has_zones=false
        if [[ ${#BLAST_ZONE_0[@]} -gt 0 ]] || [[ ${#BLAST_ZONE_1[@]} -gt 0 ]] || [[ ${#BLAST_ZONE_2[@]} -gt 0 ]]; then
            has_zones=true
        fi

        if "$has_zones"; then
            # Zone 0 - Primary (intentionally broken)
            if [[ ${#BLAST_ZONE_0[@]} -gt 0 ]]; then
                echo -e "    ${BOLD}Zone 0 - Primary (intentionally broken):${RESET}"
                for cname in "${BLAST_ZONE_0[@]}"; do
                    _fleet_print_zone_row "$cname"
                done
                echo ""
            fi

            # Zone 1 - Immediate dependents
            echo -e "    ${BOLD}Zone 1 - Immediate dependents:${RESET}"
            if [[ ${#BLAST_ZONE_1[@]} -gt 0 ]]; then
                for cname in "${BLAST_ZONE_1[@]}"; do
                    _fleet_print_zone_row "$cname"
                done
            else
                echo -e "      ${DIM}(none affected)${RESET}"
            fi
            echo ""

            # Zone 2 - Secondary
            echo -e "    ${BOLD}Zone 2 - Secondary:${RESET}"
            if [[ ${#BLAST_ZONE_2[@]} -gt 0 ]]; then
                for cname in "${BLAST_ZONE_2[@]}"; do
                    _fleet_print_zone_row "$cname"
                done
            else
                echo -e "      ${DIM}(none affected)${RESET}"
            fi
            echo ""

            # Show any damaged containers that aren't in any zone
            local -a unzoned_damaged=()
            for cname in "${FLEET_DAMAGED[@]}"; do
                local zone
                zone="$(_fleet_container_zone "$cname")"
                [[ "$zone" == "-" ]] && unzoned_damaged+=("$cname")
            done

            if [[ ${#unzoned_damaged[@]} -gt 0 ]]; then
                echo -e "    ${BOLD}Outside blast radius (unexpected):${RESET}"
                for cname in "${unzoned_damaged[@]}"; do
                    _fleet_print_zone_row "$cname"
                done
                echo ""
            fi
        else
            # No zones computed, flat listing
            printf "    %-24s %-12s %s\n" "Container" "Status" "Reason"
            printf "    %-24s %-12s %s\n" "---------" "------" "------"

            for cname in "${FLEET_DAMAGED[@]}"; do
                local status="${FLEET_STATUS[$cname]:-DAMAGED}"
                local reason="${FLEET_DAMAGE_REASON[$cname]:-}"
                local status_color="${RESET}"

                case "$status" in
                    RESTARTED) status_color="${YELLOW}" ;;
                    FAILED)    status_color="${RED}" ;;
                    DAMAGED)   status_color="${RED}" ;;
                esac

                printf "    %-24s ${status_color}%-12s${RESET} %s\n" \
                    "$cname" "$status" "$reason"
            done
            echo ""
        fi

        # Unaffected count
        local unaffected=0
        for cname in "${FLEET_CONTAINERS[@]}"; do
            local st="${FLEET_STATUS[$cname]:-SKIP}"
            [[ "$st" == "HEALTHY" ]] && (( unaffected++ ))
        done
        echo -e "    Unaffected: ${GREEN}${unaffected}${RESET} containers"
    fi

    # Verdict line
    if [[ $still_broken -gt 0 ]]; then
        local broken_names
        broken_names=$(IFS=', '; echo "${FLEET_STILL_BROKEN[*]}")
        echo -e "    Fleet verdict: ${RED}${BOLD}FAIL${RESET} (${damaged} damaged, ${restarted} recovered, ${still_broken} still broken: ${broken_names})"
    elif [[ $damaged -gt 0 ]]; then
        echo -e "    Fleet verdict: ${GREEN}${BOLD}PASS${RESET} (${damaged} damaged, ${restarted} recovered, 0 still broken)"
    else
        echo -e "    Fleet verdict: ${GREEN}${BOLD}PASS${RESET} (no collateral damage)"
    fi
}

# ── fleet_reset ──────────────────────────────────────────────────────
# Clear per-round tracking arrays for the next round.
fleet_reset() {
    BLAST_ZONE_0=()
    BLAST_ZONE_1=()
    BLAST_ZONE_2=()
    FLEET_STATUS=()
    FLEET_RECOVERY_SEC=()
    FLEET_DAMAGE_REASON=()
    FLEET_DAMAGED=()
    FLEET_RESTARTED=()
    FLEET_STILL_BROKEN=()
}
