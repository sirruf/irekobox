import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.Socket;
import java.util.Map;
import org.testcontainers.DockerClientFactory;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.wait.strategy.Wait;
import org.testcontainers.utility.DockerImageName;

// Testcontainers for Java against the Docker API: start redis, talk to it, stop.
public class RedisCheck {
    public static void main(String[] args) throws Exception {
        // Testcontainers falls back to other sockets: make sure this is us.
        String os = DockerClientFactory.instance().getInfo().getOperatingSystem();
        if (os == null || !os.contains("Irekobox")) throw new IllegalStateException("not Irekobox: " + os);
        try (GenericContainer<?> redis = new GenericContainer<>(DockerImageName.parse("redis:7-alpine"))
                .withExposedPorts(6379)
                .withLabels(Map.of("com.irekobox.conformance", "1"))
                .waitingFor(Wait.forLogMessage(".*Ready to accept connections.*", 1))) {
            redis.start();
            try (Socket socket = new Socket(redis.getHost(), redis.getMappedPort(6379))) {
                OutputStream out = socket.getOutputStream();
                out.write("PING\r\n".getBytes());
                out.flush();
                String reply = new BufferedReader(new InputStreamReader(socket.getInputStream())).readLine();
                if (!"+PONG".equals(reply)) throw new IllegalStateException("reply " + reply);
            }
            var result = redis.execInContainer("redis-cli", "ping");
            if (result.getExitCode() != 0 || !result.getStdout().contains("PONG")) {
                throw new IllegalStateException("exec " + result.getExitCode() + " " + result.getStdout());
            }
        }
        System.out.println("ok");
    }
}
