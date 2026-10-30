#!/bin/bash
# Conformance harness: real Docker clients against Irekobox's Docker API.
#
#   scripts/conformance/run.sh                 # the agent's socket (Settings > Docker on)
#   scripts/conformance/run.sh --dev           # start the development runner on a temp socket
#   scripts/conformance/run.sh --only compose  # one group: cli, volumes, networks, build, compose,
#                                              # events, images, restart, testcontainers-node,
#                                              # testcontainers-go, testcontainers-java, devcontainers
#
# Every resource it makes is named ibc-* and labelled com.irekobox.conformance=1;
# cleanup removes only those. Prints PASS/FAIL/SKIP per check and a summary line.

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/scripts/conformance"
CACHE="${HOME}/Library/Caches/irekobox-conformance"
LABEL="com.irekobox.conformance=1"
ONLY=""
DEV=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dev) DEV=1 ;;
        --only) shift; ONLY="$1" ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

PASS=0; FAIL=0; SKIP=0
HAD_BUILDKIT=1
WORK="$(mktemp -d "${TMPDIR:-/tmp}/czc.XXXXXX")"
DEV_PID=""

if [ "$DEV" = 1 ]; then
    (cd "$ROOT/ContainerKit" && swift build --product DockerAPIDev >/dev/null 2>&1) || { echo "build of DockerAPIDev failed" >&2; exit 2; }
    BIN="$(cd "$ROOT/ContainerKit" && swift build --product DockerAPIDev --show-bin-path)/DockerAPIDev"
    SOCKET="$WORK/docker.sock"
    "$BIN" "$SOCKET" >"$WORK/dev.log" 2>&1 &
    DEV_PID=$!
    for _ in $(seq 1 50); do [ -S "$SOCKET" ] && break; sleep 0.1; done
else
    SOCKET="$HOME/.irekobox/docker.sock"
fi
export DOCKER_HOST="unix://$SOCKET"
export DOCKER_CLI_HINTS=false

cleanup() {
    # buildx boots its own BuildKit container: remove it if this run made it.
    if [ "$HAD_BUILDKIT" = 0 ]; then
        docker rm -f buildx_buildkit_default >/dev/null 2>&1
        docker volume rm buildx_buildkit_default_state >/dev/null 2>&1
        docker rmi moby/buildkit:buildx-stable-1 >/dev/null 2>&1
    fi
    docker ps -aq --filter "label=$LABEL" | xargs -n 20 docker rm -f >/dev/null 2>&1
    docker network ls -q --filter "label=$LABEL" | xargs -n 20 docker network rm >/dev/null 2>&1
    docker volume ls -q --filter "label=$LABEL" | xargs -n 20 docker volume rm >/dev/null 2>&1
    for image in $(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^ibc-'); do docker rmi -f "$image" >/dev/null 2>&1; done
    [ -n "$DEV_PID" ] && kill "$DEV_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

wanted() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }
check() {   # check "name" command...
    local name="$1"; shift
    local out
    if out="$("$@" 2>&1)"; then
        printf 'PASS  %s\n' "$name"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s\n' "$name"; printf '      %s\n' "$(printf '%s' "$out" | tail -3 | tr '\n' ' ' | cut -c1-200)"
        FAIL=$((FAIL + 1))
    fi
}
skip() { printf 'SKIP  %s (%s)\n' "$1" "$2"; SKIP=$((SKIP + 1)); }
equals() { [ "$1" = "$2" ] || { echo "expected '$2', got '$1'"; return 1; }; }
contains() { case "$1" in *"$2"*) return 0 ;; *) echo "'$2' not in: $1"; return 1 ;; esac; }
export -f equals contains
L=(--label "$LABEL")

docker version --format '{{.Server.Version}}' >/dev/null 2>&1 || { echo "no Docker API at $SOCKET" >&2; exit 2; }
docker inspect buildx_buildkit_default >/dev/null 2>&1 || HAD_BUILDKIT=0
echo "Docker API at $SOCKET: server $(docker version --format '{{.Server.Version}} (API {{.Server.APIVersion}})'), client $(docker version --format '{{.Client.Version}}')"

if wanted cli; then
    check "version and info" docker info --format '{{.OperatingSystem}}'
    check "pull" docker pull -q alpine:latest
    check "run --rm prints output" bash -c 'equals "$(docker run --rm '"${L[*]}"' alpine:latest echo hello)" hello'
    check "exit code passes through" bash -c 'docker run --rm '"${L[*]}"' alpine:latest sh -c "exit 3"; equals $? 3'
    check "stdin with -i" bash -c 'equals "$(echo piped | docker run --rm -i '"${L[*]}"' alpine:latest cat)" piped'
    check "run -d with a published port" docker run -d --name ibc-web "${L[@]}" -p 18181:80 nginx:alpine
    check "port answers" bash -c 'for i in $(seq 1 30); do curl -sf -o /dev/null http://localhost:18181/ && exit 0; sleep 0.5; done; exit 1'
    check "ps shows it" bash -c 'contains "$(docker ps --format "{{.Names}} {{.Ports}}")" "ibc-web"'
    check "logs" bash -c 'docker logs ibc-web 2>&1 | grep -q nginx'
    check "exec" bash -c 'equals "$(docker exec ibc-web sh -c "echo \$((6 * 7))")" 42'
    check "exec exit code" bash -c 'docker exec ibc-web sh -c "exit 5"; equals $? 5'
    check "stats --no-stream" docker stats --no-stream ibc-web
    check "top" bash -c 'docker top ibc-web | grep -q nginx'
    check "cp in and out" bash -c 'echo cp-ok > '"$WORK"'/f && docker cp '"$WORK"'/f ibc-web:/tmp/f && docker cp ibc-web:/tmp/f '"$WORK"'/g && equals "$(cat '"$WORK"'/g)" cp-ok'
    check "inspect" bash -c 'equals "$(docker inspect -f "{{.State.Running}}" ibc-web)" true'
    check "restart" docker restart -t 1 ibc-web
    check "stop" docker stop -t 1 ibc-web
    check "stopped state" bash -c 'equals "$(docker inspect -f "{{.State.Status}}" ibc-web)" exited'
    check "rm" docker rm ibc-web
    check "wait returns the code" bash -c 'docker run -d --name ibc-wait '"${L[*]}"' alpine:latest sh -c "sleep 1; exit 4" >/dev/null && equals "$(docker wait ibc-wait)" 4'
fi

if wanted volumes; then
    check "volume create" docker volume create "${L[@]}" ibc-vol
    check "data survives between containers" bash -c 'docker run --rm '"${L[*]}"' -v ibc-vol:/data alpine:latest sh -c "echo kept > /data/x" && equals "$(docker run --rm '"${L[*]}"' -v ibc-vol:/data alpine:latest cat /data/x)" kept'
    check "volume ls filter" bash -c 'contains "$(docker volume ls -q --filter label='"$LABEL"')" ibc-vol'
    check "volume rm" docker volume rm ibc-vol
fi

if wanted networks; then
    check "network create" docker network create "${L[@]}" ibc-net
    check "server on the network" docker run -d --name ibc-srv --network ibc-net --network-alias db "${L[@]}" redis:7-alpine
    check "name resolves on the network" bash -c 'sleep 2; docker run --rm --network ibc-net '"${L[*]}"' alpine:latest sh -c "getent hosts ibc-srv"'
    check "alias resolves on the network" bash -c 'docker run --rm --network ibc-net '"${L[*]}"' redis:7-alpine sh -c "sleep 2; redis-cli -h db ping" | grep -q PONG'
    check "network inspect lists it" bash -c 'contains "$(docker network inspect ibc-net -f "{{range .Containers}}{{.Name}} {{end}}")" ibc-srv'
    docker rm -f ibc-srv >/dev/null 2>&1
    check "network rm" docker network rm ibc-net
fi

if wanted build; then
    mkdir -p "$WORK/build"
    printf 'FROM alpine:latest\nARG WORD=default\nRUN echo "$WORD" > /word\nCMD ["cat","/word"]\n' > "$WORK/build/Dockerfile"
    check "classic build" bash -c 'DOCKER_BUILDKIT=0 docker build -q --build-arg WORD=classic -t ibc-build:classic '"$WORK"'/build'
    check "classic build output" bash -c 'equals "$(docker run --rm '"${L[*]}"' ibc-build:classic)" classic'
    check "buildx build --load" bash -c 'docker build --load --build-arg WORD=buildx -t ibc-build:buildx '"$WORK"'/build'
    check "buildx build output" bash -c 'equals "$(docker run --rm '"${L[*]}"' ibc-build:buildx)" buildx'
fi

if wanted compose; then
    mkdir -p "$WORK/compose"
    cat > "$WORK/compose/compose.yaml" <<'YAML'
name: czc
services:
  web:
    image: nginx:alpine
    ports: ["18182:80"]
    labels: [com.irekobox.conformance=1]
  cache:
    image: redis:7-alpine
    volumes: [data:/data]
    labels: [com.irekobox.conformance=1]
volumes:
  data:
    labels: [com.irekobox.conformance=1]
networks:
  default:
    labels: [com.irekobox.conformance=1]
YAML
    check "compose up -d" bash -c 'cd '"$WORK"'/compose && docker compose up -d'
    check "compose ps" bash -c 'cd '"$WORK"'/compose && equals "$(docker compose ps --format "{{.Service}}" | sort | tr "\n" " ")" "cache web "'
    check "service name resolves" bash -c 'cd '"$WORK"'/compose && sleep 2 && docker compose exec -T web sh -c "nc -z -w 2 cache 6379"'
    check "published port" bash -c 'for i in $(seq 1 30); do curl -sf -o /dev/null http://localhost:18182/ && exit 0; sleep 0.5; done; exit 1'
    check "compose logs" bash -c 'cd '"$WORK"'/compose && docker compose logs cache | grep -qi ready'
    check "compose down -v" bash -c 'cd '"$WORK"'/compose && docker compose down -v'
    check "nothing left" bash -c 'equals "$(docker ps -aq --filter label=com.docker.compose.project=czc | wc -l | tr -d " ")" 0'
fi

if wanted events; then
    docker events --filter type=container --filter "label=$LABEL" --format '{{.Action}}' > "$WORK/events" 2>&1 &
    EV=$!
    sleep 2
    docker run --rm "${L[@]}" alpine:latest sh -c 'sleep 2' >/dev/null 2>&1
    sleep 3
    kill $EV 2>/dev/null
    check "events: create start die destroy" bash -c 'equals "$(grep -E "^(create|start|die|destroy)$" '"$WORK"'/events | tr "\n" " ")" "create start die destroy "'
fi

if wanted images; then
    check "tag" docker tag alpine:latest ibc-tag:1
    check "image inspect" bash -c 'equals "$(docker image inspect -f "{{.Os}}" ibc-tag:1)" linux'
    check "save and load" bash -c 'docker save ibc-tag:1 -o '"$WORK"'/i.tar && docker rmi ibc-tag:1 >/dev/null && docker load -i '"$WORK"'/i.tar | grep -q ibc-tag'
    check "rmi" docker rmi ibc-tag:1
    check "system df" docker system df
fi

if wanted restart; then
    docker run -d --name ibc-flaky --restart on-failure:2 "${L[@]}" alpine:latest sh -c 'sleep 1; exit 1' >/dev/null
    check "on-failure:2 restarts twice" bash -c 'for i in $(seq 1 40); do [ "$(docker inspect -f "{{.RestartCount}} {{.State.Status}}" ibc-flaky)" = "2 exited" ] && exit 0; sleep 0.5; done; docker inspect -f "{{.RestartCount}} {{.State.Status}}" ibc-flaky; exit 1'
fi

# Testcontainers: Ryuk mounts the Docker socket into a container, which a VM
# can't receive; the run disables it (cleanup is ours).
export TESTCONTAINERS_RYUK_DISABLED=true

if wanted testcontainers-node; then
    if command -v npm >/dev/null; then
        mkdir -p "$CACHE/node"
        cp "$HERE/node/package.json" "$HERE/node/test.mjs" "$CACHE/node/"
        if (cd "$CACHE/node" && npm install --silent --no-audit --no-fund >/dev/null 2>&1); then
            check "testcontainers-node: redis" bash -c 'cd '"$CACHE"'/node && node test.mjs'
        else
            skip "testcontainers-node" "npm install failed"
        fi
    else
        skip "testcontainers-node" "npm not installed"
    fi
fi

if wanted testcontainers-go; then
    if command -v go >/dev/null; then
        mkdir -p "$CACHE/go"
        cp "$HERE/go/go.mod" "$HERE/go/main_test.go" "$CACHE/go/"
        check "testcontainers-go: redis" bash -c 'cd '"$CACHE"'/go && go mod tidy >/dev/null 2>&1 && go test -count=1 ./...'
    else
        skip "testcontainers-go" "go not installed"
    fi
fi

if wanted testcontainers-java; then
    # A JDK: JAVA_HOME, else the one inside Android Studio or IntelliJ.
    JAVA=""
    for home in "${JAVA_HOME:-}" "$HOME/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
                "/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
                "/Applications/IntelliJ IDEA.app/Contents/jbr/Contents/Home"; do
        [ -n "$home" ] && [ -x "$home/bin/java" ] && { JAVA="$home"; break; }
    done
    # Maven on PATH, else one unpacked into the harness cache by hand.
    MVN="$(command -v mvn)"
    [ -z "$MVN" ] && MVN="$(ls "$CACHE"/maven/apache-maven-*/bin/mvn 2>/dev/null | tail -1)"
    if [ -z "$JAVA" ]; then
        skip "testcontainers-java" "no JDK found (set JAVA_HOME)"
    elif [ -z "$MVN" ]; then
        skip "testcontainers-java" "needs Maven to resolve Testcontainers (brew install maven, or unpack it into $CACHE/maven)"
    else
        mkdir -p "$CACHE/java"
        cp "$HERE/java/pom.xml" "$HERE/java/RedisCheck.java" "$CACHE/java/"
        if (cd "$CACHE/java" && JAVA_HOME="$JAVA" "$MVN" -q dependency:build-classpath -Dmdep.outputFile=cp.txt >/dev/null 2>&1); then
            check "testcontainers-java: redis" bash -c 'cd '"$CACHE"'/java && "'"$JAVA"'/bin/java" -cp "$(cat cp.txt)" RedisCheck.java'
        else
            skip "testcontainers-java" "resolving Testcontainers with Maven failed"
        fi
    fi
fi

if wanted devcontainers; then
    DEVCONTAINER="$(command -v devcontainer)"
    if [ -z "$DEVCONTAINER" ] && command -v npm >/dev/null; then
        # Into the harness cache, not a global install.
        mkdir -p "$CACHE/devcontainers"
        (cd "$CACHE/devcontainers" && [ -x node_modules/.bin/devcontainer ] \
            || npm install --silent --no-audit --no-fund @devcontainers/cli >/dev/null 2>&1)
        [ -x "$CACHE/devcontainers/node_modules/.bin/devcontainer" ] && DEVCONTAINER="$CACHE/devcontainers/node_modules/.bin/devcontainer"
    fi
    if [ -n "$DEVCONTAINER" ]; then
        mkdir -p "$WORK/dev/.devcontainer"
        printf '{"image":"alpine:latest","runArgs":["--label","%s"]}\n' "$LABEL" > "$WORK/dev/.devcontainer/devcontainer.json"
        check "devcontainer up" "$DEVCONTAINER" up --workspace-folder "$WORK/dev"
        check "devcontainer exec" bash -c 'equals "$('"$DEVCONTAINER"' exec --workspace-folder '"$WORK"'/dev echo inside)" inside'
    else
        skip "devcontainers" "no devcontainer CLI and no npm"
    fi
fi

echo "---"
echo "passed $PASS, failed $FAIL, skipped $SKIP"
[ "$FAIL" = 0 ]
