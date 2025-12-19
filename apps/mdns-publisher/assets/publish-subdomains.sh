#!/bin/bash
# HaLOS mDNS Publisher
# Advertises *.halos.local subdomains via Avahi/mDNS
#
# This script monitors Docker containers for the `halos.subdomain` label
# and uses avahi-publish to advertise the corresponding subdomains.

set -e

# Configuration
DOMAIN="${HALOS_DOMAIN:-halos.local}"
PID_DIR="/tmp/mdns-publisher"

# Create PID directory
mkdir -p "$PID_DIR"

# Get host IP address from default route
get_host_ip() {
    # Get the IP of the interface used for the default route
    ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' || \
    hostname -I 2>/dev/null | awk '{print $1}' || \
    echo "127.0.0.1"
}

HOST_IP=$(get_host_ip)
echo "Host IP: $HOST_IP"
echo "Domain: $DOMAIN"

# Start avahi-publish for a subdomain
start_publish() {
    local container_id="$1"
    local subdomain="$2"
    local pid_file="$PID_DIR/${container_id}.pid"

    # Skip if empty subdomain (means root domain, handled elsewhere)
    if [ -z "$subdomain" ]; then
        echo "Container $container_id: empty subdomain (root domain), skipping"
        return
    fi

    # Skip if already running
    if [ -f "$pid_file" ]; then
        local old_pid
        old_pid=$(cat "$pid_file")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "Container $container_id: already publishing $subdomain.$DOMAIN"
            return
        fi
        rm -f "$pid_file"
    fi

    local fqdn="$subdomain.$DOMAIN"
    echo "Starting: $fqdn -> $HOST_IP"

    # Start avahi-publish in background
    avahi-publish -a "$fqdn" "$HOST_IP" &
    local pid=$!
    echo "$pid" > "$pid_file"
    echo "Started avahi-publish for $fqdn (PID: $pid)"
}

# Stop avahi-publish for a container
stop_publish() {
    local container_id="$1"
    local pid_file="$PID_DIR/${container_id}.pid"

    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            echo "Stopping avahi-publish (PID: $pid)"
            kill "$pid" 2>/dev/null || true
        fi
        rm -f "$pid_file"
    fi
}

# Scan a container for halos.subdomain label
scan_container() {
    local container_id="$1"

    local subdomain
    subdomain=$(docker inspect --format '{{index .Config.Labels "halos.subdomain"}}' "$container_id" 2>/dev/null || echo "")

    if [ -n "$subdomain" ] && [ "$subdomain" != "<no value>" ]; then
        # Container ID is truncated in events, use full ID from inspect
        local full_id
        full_id=$(docker inspect --format '{{.Id}}' "$container_id" 2>/dev/null || echo "$container_id")
        start_publish "$full_id" "$subdomain"
    fi
}

# Scan all running containers
scan_all_containers() {
    echo "Scanning existing containers..."
    local containers
    containers=$(docker ps --format '{{.ID}}' 2>/dev/null || echo "")

    for container_id in $containers; do
        scan_container "$container_id"
    done
    echo "Initial scan complete"
}

# Cleanup on exit
cleanup() {
    echo "Cleaning up..."
    for pid_file in "$PID_DIR"/*.pid; do
        if [ -f "$pid_file" ]; then
            local pid
            pid=$(cat "$pid_file")
            kill "$pid" 2>/dev/null || true
            rm -f "$pid_file"
        fi
    done
    echo "Cleanup complete"
}

trap cleanup EXIT INT TERM

# Main loop
main() {
    echo "HaLOS mDNS Publisher starting..."

    # Wait for Docker to be available
    while ! docker info >/dev/null 2>&1; do
        echo "Waiting for Docker..."
        sleep 2
    done

    # Initial scan
    scan_all_containers

    echo "Monitoring Docker events..."

    # Monitor Docker events
    docker events --filter 'type=container' --format '{{.Status}} {{.ID}}' | while read -r status container_id; do
        case "$status" in
            start)
                echo "Container started: $container_id"
                scan_container "$container_id"
                ;;
            stop|die|kill)
                echo "Container stopped: $container_id"
                # Get full container ID for PID file lookup
                local full_id
                full_id=$(docker inspect --format '{{.Id}}' "$container_id" 2>/dev/null || echo "$container_id")
                stop_publish "$full_id"
                ;;
        esac
    done
}

main "$@"
