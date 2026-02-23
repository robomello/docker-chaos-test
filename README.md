# docker-chaos-test

Inject faults into Docker infrastructure, measure recovery time, and ship a self-healing library you can drop into any system watcher.

## What it does

1. **Breaks things on purpose** - stops containers, corrupts socket permissions, fills disks, poisons DNS, pauses Postgres, simulates NVMe wear.
2. **Measures recovery** - records time-to-detect and time-to-heal for each fault.
3. **Packages the healing logic** as `lib/self-heal.sh` - a sourceable library you use in production without the chaos runner.

## Quick Start

```bash
git clone <repo> docker-chaos-test
cd docker-chaos-test
cp chaos-test.conf.example chaos-test.conf  # edit for your env
./chaos-test.sh --dry-run --list-modules    # see what would happen
./chaos-test.sh --modules dns,postgres --self-heal
```

## Architecture

```
docker-chaos-test/
  chaos-test.sh          # CLI runner: inject faults, measure recovery
  lib/
    common.sh            # Logging, snapshots, alerting primitives
    self-heal.sh         # Sourceable library: run_all_health_checks()
    fleet.sh             # Fleet-wide steady-state verification
    modules/
      cloudflare.sh      # Cloudflare tunnel stop/start
      disk-space.sh      # Fill mount with sparse file
      dns.sh             # Poison /etc/resolv.conf
      docker-socket.sh   # Corrupt socket permissions
      nvme-health.sh     # NVMe SMART monitoring (read-only)
      postgres.sh        # Pause/unpause + connection drain
  examples/
    system-watcher-integration.sh
    custom-module.sh
    telegram-alerts.sh
  chaos-test.conf.example
```

**Three distinct parts:**

- `chaos-test.sh` - runs a test campaign: break -> wait -> measure -> verify fleet -> heal -> report. For CI or scheduled drills.
- `lib/self-heal.sh` - production library. Source it, call `run_all_health_checks()`. No chaos injection, just detect and fix.
- `lib/fleet.sh` - steady-state fleet verification. Snapshots all containers before chaos, detects collateral damage after recovery.

## Fleet Verification

After each chaos round recovers, the runner verifies **every running container** -- not just the module you broke. This catches collateral damage (e.g., postgres recovers but n8n stays down).

Inspired by LitmusChaos SoT/EoT probes (Start/End of Test steady-state checks).

**How it works:**

1. Before chaos: `fleet_snapshot()` records all running containers + health URLs
2. After module recovery: `fleet_verify()` compares current state vs snapshot
3. Any divergence = collateral damage. Containers that stopped or failed health checks get flagged
4. `fleet_heal()` restarts damaged containers in dependency order (parents before children)

**Configure services with health URLs and dependencies:**

```bash
CHAOS_FLEET_SERVICES=(
    "n8n-postgres|||120"
    "n8n-main|http://localhost:5678/healthz|n8n-postgres,n8n-redis|60"
    "comfyui|http://localhost:8188/system_stats||300"
)
```

Format: `container|health_url|depends_on|timeout` (pipe-delimited to avoid `://` collision)

Containers not in `CHAOS_FLEET_SERVICES` are auto-discovered via `docker ps` and get running-check only (no health URL).

**Skip containers** with `CHAOS_FLEET_SKIP` regex:

```bash
CHAOS_FLEET_SKIP="supabase-|n8n-db-cleaner"
```

**Strategies:**
- `restart` (default): auto-restart damaged containers, poll for recovery
- `report`: log damage but don't restart

**Disable fleet checks** with `--no-fleet` for fast module-only testing.

### Blast Radius Zones

When a module breaks a container, the fleet classifies all other containers into zones based on the dependency graph:

| Zone | Description | Example (postgres module) |
|------|-------------|---------------------------|
| **Zone 0** | Primary - intentionally broken containers | `n8n-postgres` |
| **Zone 1** | Immediate - direct dependents of zone 0 | `n8n-main`, `n8n-worker-*`, `claude-telegram` |
| **Zone 2** | Secondary - transitive dependents of zone 1 | (containers depending on zone 1) |
| **Unzoned** | Not in dependency graph but still damaged | Unexpected collateral damage |

Zone classification uses `CHAOS_MODULE_CONTAINERS_*` mappings to identify which containers a module directly affects, then walks the `depends_on` graph to find zone 1 and zone 2.

Configure mappings:

```bash
CHAOS_MODULE_CONTAINERS_postgres="n8n-postgres"
CHAOS_MODULE_CONTAINERS_cloudflare="cloudflared"
CHAOS_MODULE_CONTAINERS_docker_socket=""   # host-level, no specific container
```

### Steady-State Probes

Inspired by LitmusChaos SoT/EoT (Start/End of Test) probes:

1. **SoT probe** (`fleet_snapshot`): Before chaos begins, record the running state and health of every container. This is the steady-state hypothesis.
2. **Chaos injection**: Break the target module(s).
3. **Module recovery**: Wait for module self-heal or timeout.
4. **EoT probe** (`fleet_verify`): Compare current state against the snapshot. Any divergence = collateral damage.
5. **Heal** (`fleet_heal`): Restart damaged containers in dependency order (parents before children).
6. **Report** (`fleet_report`): Zone-based breakdown with recovery times.

## Module Interface

Every module implements five functions:

```bash
<name>_describe()   # one-line or multi-line description
<name>_check()      # return 0 healthy, 1 broken
<name>_break()      # inject the fault (respects CHAOS_DRY_RUN)
<name>_heal()       # fix the fault, verify fixed, return 0 on success
<name>_restore()    # emergency restore from snapshot, last resort
```

Example skeleton:

```bash
register_module "myservice"

myservice_check() {
    curl -sf http://localhost:9000/health >/dev/null 2>&1
}

myservice_break() {
    [[ "$CHAOS_DRY_RUN" == "true" ]] && { echo "[DRY RUN] would stop myservice"; return 0; }
    docker stop myservice
}

myservice_heal() {
    docker start myservice
    sleep 3
    myservice_check
}

myservice_restore() {
    docker start myservice
}
```

## Available Modules

| Module | What it tests | What it breaks | Read-only? |
|--------|--------------|----------------|------------|
| `dns` | Host + container DNS resolution | Overwrites `/etc/resolv.conf` with unreachable nameserver | No |
| `postgres` | DB availability and connection count | `docker pause` (simulates unresponsive DB) | No |
| `docker-socket` | Docker socket accessibility | Changes socket group ownership and permissions | No |
| `cloudflare` | Cloudflare tunnel container liveness | `docker stop` on the tunnel container | No |
| `disk-space` | Mount point free space | Fills mount with large sparse file via `dd`, leaving only `CHAOS_DISK_RESERVE_MB` free | No |
| `nvme-health` | NVMe SMART data (wear, temp, errors, spare) | Nothing - monitoring only | Yes |

## Usage

```bash
# List all modules with descriptions
./chaos-test.sh --list-modules

# Dry run - show what would happen, touch nothing
./chaos-test.sh --dry-run

# Run one round against all modules, self-heal after each break
./chaos-test.sh --self-heal

# Target specific modules, 3 rounds
./chaos-test.sh --rounds 3 --modules dns,postgres --self-heal

# Increase recovery timeout (default 120s)
./chaos-test.sh --modules disk-space --timeout 300 --self-heal

# Load config file
./chaos-test.sh --config /etc/chaos-test.conf --self-heal

# Emergency restore from last snapshot (no chaos injection)
./chaos-test.sh --restore --modules docker-socket

# Verbose output
./chaos-test.sh --verbose --modules postgres
```

## Self-Healing Library

Use `lib/self-heal.sh` in your own watcher without running chaos tests:

```bash
source /opt/docker-chaos-test/lib/self-heal.sh

# Check + heal all modules; returns number of failures
failed=$(run_all_health_checks)

# Or target a single module
run_module_check postgres      # 0=healthy, 1=heal failed, 2=unknown module

# Inject chaos manually (for testing your watcher)
run_module_break dns
```

Full integration example: `examples/system-watcher-integration.sh`

## Configuration

All settings have sane defaults. Override via environment or config file:

```bash
cp chaos-test.conf.example chaos-test.conf
# edit chaos-test.conf
./chaos-test.sh --config chaos-test.conf
```

Key variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `CHAOS_POSTGRES_CONTAINER` | `postgres` | Postgres container name |
| `CHAOS_POSTGRES_USER` | `postgres` | Postgres superuser |
| `CHAOS_CLOUDFLARE_CONTAINER` | `cloudflared` | Tunnel container name |
| `CHAOS_DNS_TEST_HOST` | `google.com` | Host to resolve for DNS check |
| `CHAOS_DISK_MOUNTS` | `/` | Space-separated mount points to monitor |
| `CHAOS_DISK_WARN_PCT` | `90` | Warn threshold (%) |
| `CHAOS_DISK_CRIT_PCT` | `95` | Critical threshold (%) |
| `CHAOS_DISK_RESERVE_MB` | `500` | Minimum free MB to preserve when breaking |
| `CHAOS_NVME_DEVICE` | `auto` | NVMe device (`auto` detects first NVMe) |
| `CHAOS_NVME_TEMP_WARN` | `70` | Temperature warning threshold (C) |
| `CHAOS_ALERT_COOLDOWN` | `300` | Seconds between repeated alerts for same issue |
| `CHAOS_FLEET_SERVICES` | `()` | Fleet service registry (see Fleet Verification) |
| `CHAOS_FLEET_SKIP` | `""` | Regex of container names to skip in fleet checks |
| `CHAOS_FLEET_TIMEOUT` | `90` | Default per-service recovery timeout (seconds) |
| `CHAOS_FLEET_STRATEGY` | `restart` | Fleet heal strategy: `restart` or `report` |
| `CHAOS_LOG_FILE` | `/tmp/chaos-test.log` | Log output path |
| `CHAOS_VERBOSE` | `false` | Enable debug logging |

Full reference: `chaos-test.conf.example`

## Writing Custom Modules

Copy the template and drop it in `lib/modules/`:

```bash
cp examples/custom-module.sh lib/modules/myservice.sh
# edit lib/modules/myservice.sh
```

Modules are auto-discovered - any `.sh` file in `lib/modules/` is sourced automatically. No registration in a central file required.

See `examples/custom-module.sh` for a fully commented template.

## Alerting

Set `ALERT_CALLBACK` to any function name before sourcing `self-heal.sh`. The function receives `(message, level)` where level is `info`, `warn`, or `error`.

```bash
my_alert() {
    local message=$1 level=$2
    curl -sf "https://hooks.slack.com/..." -d "{\"text\":\"[$level] $message\"}"
}
export ALERT_CALLBACK="my_alert"
export -f my_alert

source /opt/docker-chaos-test/lib/self-heal.sh
run_all_health_checks
```

Telegram example: `examples/telegram-alerts.sh`

Duplicate alerts are suppressed for `CHAOS_ALERT_COOLDOWN` seconds (default 300s) per issue.

## Requirements

- bash 4.0+
- Docker (socket accessible to running user)
- `curl` (Cloudflare check, optional alerting)
- `dig` or `host` (DNS check)
- `smartctl` from `smartmontools` (NVMe health module)
- `python3` (container-side DNS check, optional)
- `sudo` (DNS restore via `systemctl restart systemd-resolved`)

Install optional deps on Debian/Ubuntu:

```bash
apt-get install -y smartmontools dnsutils
```

## License

MIT - see `LICENSE`.
