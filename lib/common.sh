#!/bin/bash
# common.sh - Shared utilities for docker-chaos-test
# Logging, colors, alerts, config loading, prerequisites

# Prevent double-sourcing
[[ -n "${_CHAOS_COMMON_LOADED:-}" ]] && return 0
_CHAOS_COMMON_LOADED=1

# ── Colors ────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' RESET=''
fi

# ── Defaults ──────────────────────────────────────────────────────────
CHAOS_LOG_FILE="${CHAOS_LOG_FILE:-/tmp/chaos-test.log}"
CHAOS_STATE_DIR=""  # set by init_state_dir
CHAOS_VERBOSE="${CHAOS_VERBOSE:-false}"
CHAOS_DRY_RUN="${CHAOS_DRY_RUN:-false}"
CHAOS_ALERT_COOLDOWN="${CHAOS_ALERT_COOLDOWN:-300}"

# Module defaults (override in config or env)
CHAOS_DOCKER_SOCKET="${CHAOS_DOCKER_SOCKET:-/var/run/docker.sock}"
CHAOS_DOCKER_GROUP="${CHAOS_DOCKER_GROUP:-docker}"
CHAOS_DNS_TEST_HOST="${CHAOS_DNS_TEST_HOST:-google.com}"
CHAOS_DNS_TEST_CONTAINER="${CHAOS_DNS_TEST_CONTAINER:-}"
CHAOS_POSTGRES_CONTAINER="${CHAOS_POSTGRES_CONTAINER:-n8n-postgres}"
CHAOS_POSTGRES_USER="${CHAOS_POSTGRES_USER:-postgres}"
CHAOS_POSTGRES_MAX_CONN="${CHAOS_POSTGRES_MAX_CONN:-100}"
CHAOS_POSTGRES_CONN_THRESHOLD="${CHAOS_POSTGRES_CONN_THRESHOLD:-80}"
CHAOS_CLOUDFLARE_CONTAINER="${CHAOS_CLOUDFLARE_CONTAINER:-cloudflared}"
CHAOS_DISK_MOUNTS="${CHAOS_DISK_MOUNTS:-/}"
CHAOS_DISK_WARN_PCT="${CHAOS_DISK_WARN_PCT:-90}"
CHAOS_DISK_CRIT_PCT="${CHAOS_DISK_CRIT_PCT:-95}"
CHAOS_DISK_RESERVE_MB="${CHAOS_DISK_RESERVE_MB:-500}"
CHAOS_NVME_DEVICE="${CHAOS_NVME_DEVICE:-auto}"
CHAOS_NVME_TEMP_WARN="${CHAOS_NVME_TEMP_WARN:-70}"
CHAOS_NVME_PCT_WARN="${CHAOS_NVME_PCT_WARN:-90}"

# Fleet verification defaults
CHAOS_FLEET_HEALTH="${CHAOS_FLEET_HEALTH:-}"
CHAOS_FLEET_SKIP="${CHAOS_FLEET_SKIP:-}"
CHAOS_FLEET_TIMEOUT="${CHAOS_FLEET_TIMEOUT:-90}"
CHAOS_FLEET_STRATEGY="${CHAOS_FLEET_STRATEGY:-restart}"

# Module-to-container mappings (for blast radius computation)
# Maps chaos module name -> container(s) it directly breaks.
# Empty = host-level fault (affects host, not a specific container).
CHAOS_MODULE_CONTAINERS_postgres="${CHAOS_MODULE_CONTAINERS_postgres:-n8n-postgres}"
CHAOS_MODULE_CONTAINERS_docker_socket="${CHAOS_MODULE_CONTAINERS_docker_socket:-}"
CHAOS_MODULE_CONTAINERS_dns="${CHAOS_MODULE_CONTAINERS_dns:-}"
CHAOS_MODULE_CONTAINERS_cloudflare="${CHAOS_MODULE_CONTAINERS_cloudflare:-cloudflared}"
CHAOS_MODULE_CONTAINERS_disk_space="${CHAOS_MODULE_CONTAINERS_disk_space:-}"
CHAOS_MODULE_CONTAINERS_nvme_health="${CHAOS_MODULE_CONTAINERS_nvme_health:-}"

# Alert callback (set to a function name to receive alerts)
ALERT_CALLBACK="${ALERT_CALLBACK:-}"

# ── State Directory ───────────────────────────────────────────────────
init_state_dir() {
    CHAOS_STATE_DIR=$(mktemp -d "/tmp/chaos-test-XXXXXX")
    chmod 700 "$CHAOS_STATE_DIR"
    mkdir -p "$CHAOS_STATE_DIR/snapshots"
    mkdir -p "$CHAOS_STATE_DIR/cooldowns"
    log_debug "State directory: $CHAOS_STATE_DIR"
}

cleanup_state_dir() {
    if [[ -n "$CHAOS_STATE_DIR" ]] && [[ -d "$CHAOS_STATE_DIR" ]]; then
        rm -rf "$CHAOS_STATE_DIR"
        log_debug "Cleaned up state directory"
    fi
}

# ── Logging ───────────────────────────────────────────────────────────
_log_ts() {
    date '+%Y-%m-%d %H:%M:%S'
}

log_info() {
    local msg="[$(_log_ts)] [INFO] $1"
    echo -e "${GREEN}${msg}${RESET}"
    echo "$msg" >> "$CHAOS_LOG_FILE" 2>/dev/null
}

log_warn() {
    local msg="[$(_log_ts)] [WARN] $1"
    echo -e "${YELLOW}${msg}${RESET}"
    echo "$msg" >> "$CHAOS_LOG_FILE" 2>/dev/null
}

log_error() {
    local msg="[$(_log_ts)] [ERROR] $1"
    echo -e "${RED}${msg}${RESET}" >&2
    echo "$msg" >> "$CHAOS_LOG_FILE" 2>/dev/null
}

log_debug() {
    if [[ "$CHAOS_VERBOSE" == "true" ]]; then
        local msg="[$(_log_ts)] [DEBUG] $1"
        echo -e "${DIM}${msg}${RESET}"
        echo "$msg" >> "$CHAOS_LOG_FILE" 2>/dev/null
    fi
}

log_action() {
    local msg="[$(_log_ts)] [ACTION] $1"
    echo -e "${CYAN}${msg}${RESET}"
    echo "$msg" >> "$CHAOS_LOG_FILE" 2>/dev/null
}

log_result() {
    local status=$1
    local msg=$2
    if [[ "$status" == "pass" ]]; then
        echo -e "${GREEN}${BOLD}  [PASS]${RESET} $msg"
    elif [[ "$status" == "fail" ]]; then
        echo -e "${RED}${BOLD}  [FAIL]${RESET} $msg"
    elif [[ "$status" == "skip" ]]; then
        echo -e "${DIM}  [SKIP]${RESET} $msg"
    fi
    echo "[$(_log_ts)] [RESULT:${status^^}] $msg" >> "$CHAOS_LOG_FILE" 2>/dev/null
}

# ── Alerts ────────────────────────────────────────────────────────────
send_alert() {
    local message=$1
    local level=${2:-info}  # info, warn, error

    log_debug "Alert ($level): $message"

    if [[ -n "$ALERT_CALLBACK" ]] && declare -f "$ALERT_CALLBACK" &>/dev/null; then
        "$ALERT_CALLBACK" "$message" "$level"
    fi
}

check_cooldown() {
    local key=$1
    local cooldown=${2:-$CHAOS_ALERT_COOLDOWN}
    local cooldown_file="$CHAOS_STATE_DIR/cooldowns/$key"

    if [[ -f "$cooldown_file" ]]; then
        local last
        last=$(cat "$cooldown_file")
        local now
        now=$(date +%s)
        if (( now - last < cooldown )); then
            return 1  # still in cooldown
        fi
    fi
    return 0  # cooldown expired or never set
}

set_cooldown() {
    local key=$1
    date +%s > "$CHAOS_STATE_DIR/cooldowns/$key"
}

# ── Snapshots ─────────────────────────────────────────────────────────
save_snapshot() {
    local module=$1
    local key=$2
    local value=$3
    local snap_dir="$CHAOS_STATE_DIR/snapshots/$module"
    mkdir -p "$snap_dir"
    echo "$value" > "$snap_dir/$key"
    log_debug "Snapshot saved: $module/$key"
}

get_snapshot() {
    local module=$1
    local key=$2
    local snap_file="$CHAOS_STATE_DIR/snapshots/$module/$key"
    if [[ -f "$snap_file" ]]; then
        cat "$snap_file"
    else
        echo ""
    fi
}

# ── Config Loading ────────────────────────────────────────────────────
load_config() {
    local config_file=$1

    if [[ -z "$config_file" ]]; then
        return 0
    fi

    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        return 1
    fi

    # Validate: only source from explicit path or script directory
    local real_config
    real_config=$(realpath "$config_file" 2>/dev/null)
    if [[ -z "$real_config" ]]; then
        log_error "Cannot resolve config path: $config_file"
        return 1
    fi

    log_info "Loading config: $real_config"
    # shellcheck source=/dev/null
    source "$real_config"
}

# ── Prerequisites ─────────────────────────────────────────────────────
check_prerequisites() {
    local missing=()

    # Required
    command -v docker &>/dev/null    || missing+=("docker")
    command -v bash &>/dev/null      || missing+=("bash")

    # Optional (warn but don't fail)
    local optional_missing=()
    command -v dig &>/dev/null       || optional_missing+=("dig (bind-utils)")
    command -v python3 &>/dev/null   || optional_missing+=("python3")
    command -v smartctl &>/dev/null  || optional_missing+=("smartctl (smartmontools)")
    command -v sudo &>/dev/null      || optional_missing+=("sudo")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        return 1
    fi

    if [[ ${#optional_missing[@]} -gt 0 ]]; then
        log_warn "Missing optional tools (some modules may be limited): ${optional_missing[*]}"
    fi

    # Check Docker access
    if ! docker info &>/dev/null; then
        log_error "Docker is not accessible. Ensure the daemon is running and you have permissions."
        return 1
    fi

    return 0
}

# ── Utility ───────────────────────────────────────────────────────────
is_container_running() {
    local name=$1
    local status
    status=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null) || return 1
    [[ "$status" == "true" ]]
}

wait_for_condition() {
    local description=$1
    local check_cmd=$2
    local timeout=${3:-60}
    local interval=${4:-2}

    local elapsed=0
    while (( elapsed < timeout )); do
        if eval "$check_cmd"; then
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    return 1
}

format_duration() {
    local seconds=$1
    if (( seconds < 60 )); then
        echo "${seconds}s"
    elif (( seconds < 3600 )); then
        echo "$((seconds / 60))m $((seconds % 60))s"
    else
        echo "$((seconds / 3600))h $((seconds % 3600 / 60))m"
    fi
}

# ── Module Registry ───────────────────────────────────────────────────
declare -a CHAOS_MODULES=()

register_module() {
    local name=$1
    CHAOS_MODULES+=("$name")
}

get_registered_modules() {
    echo "${CHAOS_MODULES[@]}"
}

is_module_registered() {
    local name=$1
    for m in "${CHAOS_MODULES[@]}"; do
        [[ "$m" == "$name" ]] && return 0
    done
    return 1
}
