#!/bin/bash
# Compatibility corpus: real Compose projects from docker/awesome-compose,
# brought up unchanged with `docker compose` against Irekobox's Docker API.
#
#   scripts/compat/run.sh                  # the agent's socket (Settings > Docker on)
#   scripts/compat/run.sh --dev            # the development runner on a temp socket
#   scripts/compat/run.sh --only flask-redis
#   scripts/compat/run.sh --host unix://$HOME/.docker/run/docker.sock   # the same corpus on another engine
#
# For each project: `up -d --wait`, then every published port must accept a
# connection (HTTP ports must answer), then `down -v`. Projects are named
# ibx-compat-*; cleanup removes only those. Results go to
# ~/Library/Caches/irekobox-compat/results.tsv, logs next to it.

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE="${HOME}/Library/Caches/irekobox-compat"
CORPUS="$CACHE/awesome-compose"
ONLY=""
DEV=0
HOST=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dev) DEV=1 ;;
        --only) shift; ONLY="$1" ;;
        --host) shift; HOST="$1" ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

PROJECTS="flask-redis nginx-flask-mysql nginx-flask-mongo nginx-golang-postgres nginx-nodejs-redis
react-express-mongodb react-express-mysql react-java-mysql django fastapi apache-php wordpress-mysql
postgresql-pgadmin gitea-postgres nextcloud-redis-mariadb prometheus-grafana spring-postgres traefik-golang"
[ -n "$ONLY" ] && PROJECTS="$ONLY"

mkdir -p "$CACHE/logs"
[ -d "$CORPUS" ] || git clone -q --depth 1 https://github.com/docker/awesome-compose.git "$CORPUS"

DEV_PID=""
if [ "$DEV" = 1 ]; then
    (cd "$ROOT/ContainerKit" && swift build --product DockerAPIDev >/dev/null 2>&1) || { echo "build of DockerAPIDev failed" >&2; exit 2; }
    BIN="$(cd "$ROOT/ContainerKit" && swift build --product DockerAPIDev --show-bin-path)/DockerAPIDev"
    SOCKET="$(mktemp -d "${TMPDIR:-/tmp}/ibx-compat.XXXXXX")/docker.sock"
    "$BIN" "$SOCKET" >"$CACHE/logs/dev-server.log" 2>&1 &
    DEV_PID=$!
    for _ in $(seq 1 50); do [ -S "$SOCKET" ] && break; sleep 0.1; done
else
    SOCKET="$HOME/.irekobox/docker.sock"
fi
export DOCKER_HOST="${HOST:-unix://$SOCKET}"
export DOCKER_CLI_HINTS=false COMPOSE_MENU=false
trap '[ -n "$DEV_PID" ] && kill "$DEV_PID" 2>/dev/null' EXIT

docker version >/dev/null 2>&1 || { echo "no Docker API at $SOCKET" >&2; exit 2; }

# Published host ports of a project, one per line.
ports() {
    docker compose -p "$1" ps --format '{{.Publishers}}' 2>/dev/null \
        | grep -oE 'PublishedPort:[0-9]+' | cut -d: -f2 | sort -un | grep -v '^0$'
}

RESULTS="$CACHE/results${HOST:+-other}.tsv"
printf "project\tresult\tseconds\tdetail\n" > "$RESULTS"
pass=0; fail=0
for project in $PROJECTS; do
    dir="$CORPUS/$project"
    name="ibx-compat-$project"
    log="$CACHE/logs/$project.log"
    [ -d "$dir" ] || { printf "%s\tSKIP\t0\tnot in corpus\n" "$project" >> "$RESULTS"; continue; }
    start=$(date +%s)
    detail=""
    if (cd "$dir" && docker compose -p "$name" up -d --build --wait --wait-timeout 420) >"$log" 2>&1; then
        sleep 5
        for port in $(ports "$name"); do
            if curl -s -o /dev/null -m 10 "http://127.0.0.1:$port/"; then
                continue
            elif nc -z -G 5 127.0.0.1 "$port" 2>/dev/null; then
                continue
            else
                detail="${detail}port $port closed; "
            fi
        done
    else
        detail="$(grep -iE 'error|failed|unsupported' "$log" | tail -1 | cut -c1-160)"
        [ -n "$detail" ] || detail="up failed"
    fi
    seconds=$(( $(date +%s) - start ))
    (cd "$dir" && docker compose -p "$name" down -v --remove-orphans --timeout 5) >>"$log" 2>&1
    if [ -z "$detail" ]; then
        result=PASS; pass=$((pass + 1))
    else
        result=FAIL; fail=$((fail + 1))
    fi
    printf "%s\t%s\t%s\t%s\n" "$project" "$result" "$seconds" "$detail" | tee -a "$RESULTS"
done
echo "== $pass passed, $fail failed (results: $RESULTS)"
