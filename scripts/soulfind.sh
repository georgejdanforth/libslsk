#!/usr/bin/env bash
#
# Start and stop a local Soulfind server for integration tests.
#
# Usage:
#   scripts/soulfind.sh up      Start Soulfind with a new, empty database.
#   scripts/soulfind.sh down    Stop Soulfind and delete its database.
#
# Environment:
#   SLSK_SOULFIND_PORT   Host port for Soulfind (default: 2242).
#   SLSK_SOULFIND_IMAGE  Docker image (default: ghcr.io/soulfind-dev/soulfind:latest).
#
# Soulfind is GPL-3.0. We run it only as an external tool. We do not vendor or link it.

set -euo pipefail

container="slsk-soulfind"
port="${SLSK_SOULFIND_PORT:-2242}"
image="${SLSK_SOULFIND_IMAGE:-ghcr.io/soulfind-dev/soulfind:latest}"
wait_seconds_max=30

usage() {
    echo "usage: $0 up|down" >&2
    exit 2
}

container_exists() {
    [ -n "$(docker ps --all --quiet --filter "name=^${container}$")" ]
}

# The image is built from scratch and has no shell, so we check the port from the host.
port_open() {
    (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null
}

up() {
    if container_exists; then
        echo "error: container '${container}' exists. Run '$0 down' first." >&2
        exit 1
    fi

    # The anonymous volume at /data holds the database. 'down' deletes it with the container,
    # so each 'up' starts with an empty database.
    docker run --detach --name "${container}" \
        --volume /data \
        --publish "127.0.0.1:${port}:2242" \
        "${image}" >/dev/null

    local waited_seconds=0
    until port_open; do
        if [ "${waited_seconds}" -ge "${wait_seconds_max}" ]; then
            echo "error: Soulfind did not open port ${port} in ${wait_seconds_max} s." >&2
            docker logs "${container}" >&2 || true
            exit 1
        fi
        sleep 1
        waited_seconds=$((waited_seconds + 1))
    done

    echo "Soulfind is running. Run the integration tests with:"
    echo "  SLSK_SOULFIND=127.0.0.1:${port} zig build itest"
}

down() {
    if container_exists; then
        docker rm --force --volumes "${container}" >/dev/null
        echo "Soulfind stopped. Its data is deleted."
    else
        echo "Soulfind is not running."
    fi
}

[ $# -eq 1 ] || usage
case "$1" in
    up) up ;;
    down) down ;;
    *) usage ;;
esac
