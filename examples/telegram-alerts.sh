#!/bin/bash
# Example: Telegram alert callback for chaos-test
# Set ALERT_CALLBACK="telegram_alert" before sourcing self-heal.sh

# Configure these
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

telegram_alert() {
    local message=$1
    local level=${2:-info}

    if [[ -z "$TELEGRAM_BOT_TOKEN" ]] || [[ -z "$TELEGRAM_CHAT_ID" ]]; then
        return 1
    fi

    local icon
    case "$level" in
        error) icon="🚨" ;;
        warn)  icon="⚠️" ;;
        *)     icon="🔧" ;;
    esac

    local text="${icon} <b>Chaos Test Alert</b>
${message}"

    curl -sf --max-time 10 \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "parse_mode=HTML" \
        -d "text=${text}" >/dev/null 2>&1
}

# Export so self-heal.sh can use it
export ALERT_CALLBACK="telegram_alert"
export -f telegram_alert
