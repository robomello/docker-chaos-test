#!/bin/bash
# Example: Adding self-healing to your system watcher
# Source the self-heal library and call run_all_health_checks() in your loop

# Point to where you installed docker-chaos-test
CHAOS_TEST_DIR="/opt/docker-chaos-test"

# Configure for your environment
export CHAOS_POSTGRES_CONTAINER="my-postgres"
export CHAOS_POSTGRES_USER="myuser"
export CHAOS_CLOUDFLARE_CONTAINER="my-tunnel"
export CHAOS_DNS_TEST_HOST="example.com"

# Optional: set up alerts
my_alert_handler() {
    local message=$1 level=$2
    # Send to your alerting system
    echo "[$level] $message"
}
export ALERT_CALLBACK="my_alert_handler"

# Source the library
source "$CHAOS_TEST_DIR/lib/self-heal.sh"

# Your existing watcher loop
while true; do
    # Your existing checks...

    # Add self-healing
    failed=$(run_all_health_checks)
    if [[ "$failed" -gt 0 ]]; then
        echo "WARNING: $failed modules could not self-heal"
    fi

    sleep 60
done
