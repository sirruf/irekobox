package conformance

import (
	"bufio"
	"context"
	"net"
	"strings"
	"testing"

	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/wait"
)

// Testcontainers for Go against the Docker API: start redis, talk to it, stop.
func TestRedis(t *testing.T) {
	ctx := context.Background()
	// Make sure this is Irekobox answering, not a fallback socket.
	docker, err := testcontainers.NewDockerClientWithOpts(ctx)
	if err != nil {
		t.Fatal(err)
	}
	info, err := docker.Info(ctx)
	if err != nil || !strings.Contains(info.OperatingSystem, "Irekobox") {
		t.Fatalf("not Irekobox: %q, err %v", info.OperatingSystem, err)
	}
	redis, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
		ContainerRequest: testcontainers.ContainerRequest{
			Image:        "redis:7-alpine",
			ExposedPorts: []string{"6379/tcp"},
			Labels:       map[string]string{"com.irekobox.conformance": "1"},
			WaitingFor:   wait.ForLog("Ready to accept connections"),
		},
		Started: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = redis.Terminate(ctx) }()

	endpoint, err := redis.PortEndpoint(ctx, "6379/tcp", "")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := net.Dial("tcp", endpoint)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.Write([]byte("PING\r\n")); err != nil {
		t.Fatal(err)
	}
	reply, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil || strings.TrimSpace(reply) != "+PONG" {
		t.Fatalf("reply %q, err %v", reply, err)
	}
	code, _, err := redis.Exec(ctx, []string{"redis-cli", "ping"})
	if err != nil || code != 0 {
		t.Fatalf("exec code %d, err %v", code, err)
	}
}
