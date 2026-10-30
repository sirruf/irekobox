// Testcontainers for Node against the Docker API: start redis, talk to it, stop.
import { GenericContainer, Wait, getContainerRuntimeClient } from "testcontainers";
import net from "node:net";

// Testcontainers falls back to other sockets (Docker Desktop) when DOCKER_HOST
// fails: make sure this is Irekobox answering.
const runtime = await getContainerRuntimeClient();
if (!runtime.info.containerRuntime.operatingSystem.includes("Irekobox")) {
  throw new Error(`not Irekobox: ${runtime.info.containerRuntime.operatingSystem}`);
}

const container = await new GenericContainer("redis:7-alpine")
  .withExposedPorts(6379)
  .withLabels({ "com.irekobox.conformance": "1" })
  .withWaitStrategy(Wait.forLogMessage("Ready to accept connections"))
  .start();
try {
  const reply = await new Promise((resolve, reject) => {
    const socket = net.connect(container.getMappedPort(6379), container.getHost(), () => socket.write("PING\r\n"));
    socket.on("data", (data) => { resolve(data.toString().trim()); socket.end(); });
    socket.on("error", reject);
  });
  if (reply !== "+PONG") throw new Error(`unexpected reply ${reply}`);
  const { output, exitCode } = await container.exec(["redis-cli", "ping"]);
  if (exitCode !== 0 || !output.includes("PONG")) throw new Error(`exec failed: ${exitCode} ${output}`);
} finally {
  await container.stop();
}
console.log("ok");
