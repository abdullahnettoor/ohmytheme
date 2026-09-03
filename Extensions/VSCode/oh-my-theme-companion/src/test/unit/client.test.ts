import * as assert from "assert";
import * as net from "net";
import * as os from "os";
import * as path from "path";
import { promises as fs } from "fs";
import { randomUUID } from "crypto";
import {
  CompanionClient,
  Rendezvous,
  readRendezvous,
} from "../../client";
import {
  CompanionMessage,
  FrameDecoder,
  decodeMessage,
  encodeMessage,
} from "../../protocol";

async function makeTempDir(): Promise<string> {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "omt-client-"));
  return dir;
}

/** Unix domain sockets are capped at 104 bytes; put them in /tmp with a short id. */
function shortSocketPath(): string {
  return path.join("/tmp", `omt-${randomUUID().slice(0, 8)}.sock`);
}

/**
 * Minimal server-side stub: accepts one connection, parses frames,
 * lets the test respond however it likes.
 */
class ServerStub {
  server: net.Server;
  socket?: net.Socket;
  received: CompanionMessage[] = [];
  private decoder = new FrameDecoder();
  private acceptResolve?: () => void;

  constructor(private readonly socketPath: string) {
    this.server = net.createServer((socket) => {
      this.socket = socket;
      socket.on("data", (chunk) => {
        this.decoder.append(chunk);
        while (true) {
          const body = this.decoder.nextFrame();
          if (!body) return;
          this.received.push(decodeMessage(body));
        }
      });
      this.acceptResolve?.();
    });
  }

  async listen(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.server.once("error", reject);
      this.server.listen(this.socketPath, () => resolve());
    });
  }

  waitForAccept(): Promise<void> {
    return new Promise((resolve) => {
      this.acceptResolve = resolve;
    });
  }

  send(message: CompanionMessage): void {
    if (!this.socket) throw new Error("no connected socket");
    this.socket.write(encodeMessage(message));
  }

  async close(): Promise<void> {
    this.socket?.destroy();
    await new Promise<void>((resolve) => this.server.close(() => resolve()));
  }
}

describe("companion client", function () {
  this.timeout(5_000);

  it("reads a rendezvous file with the required fields", async () => {
    const dir = await makeTempDir();
    const filePath = path.join(dir, "rendezvous.json");
    const rendezvous: Rendezvous = {
      socketPath: "/tmp/companion.sock",
      launchId: "launch-1",
      launchNonce: "nonce-1",
      protocolVersion: 1,
      supportedProtocolVersions: [1],
    };
    await fs.writeFile(filePath, JSON.stringify(rendezvous), { mode: 0o600 });

    const loaded = await readRendezvous(filePath);
    assert.deepStrictEqual(loaded, rendezvous);
  });

  it("rejects rendezvous files with missing fields", async () => {
    const dir = await makeTempDir();
    const filePath = path.join(dir, "rendezvous.json");
    await fs.writeFile(filePath, JSON.stringify({ launchId: "x" }));

    await assert.rejects(readRendezvous(filePath), /missing required fields/);
  });

  it("sends a register frame and resolves connect on register_ack", async () => {
    const socketPath = shortSocketPath();
    const server = new ServerStub(socketPath);
    await server.listen();
    const acceptWait = server.waitForAccept();

    const client = new CompanionClient({
      socketPath,
      launchNonce: "nonce-1",
      extensionVersion: "0.1.0",
      vscodeIdentity: {
        edition: "vscode",
        version: "1.94.0",
        profileName: "Default",
        profileId: "p",
        machineId: "m",
        sessionId: "s",
        processId: 1,
        windowId: "w",
      },
      currentSettings: {},
    });
    const connectPromise = client.connect();
    await acceptWait;

    // Wait until we have the register message.
    while (server.received.length === 0) {
      await new Promise((r) => setTimeout(r, 5));
    }
    const registerMessage = server.received[0];
    assert.strictEqual(registerMessage.type, "register");
    if (registerMessage.type === "register") {
      assert.strictEqual(registerMessage.launchNonce, "nonce-1");
      assert.deepStrictEqual(registerMessage.capabilities, ["colorTheme"]);
    }

    // Respond with a register_ack.
    server.send({
      type: "register_ack",
      protocolVersion: 1,
      id: (registerMessage as { id: string }).id,
      sessionId: "server-session-1",
    });

    const ack = await connectPromise;
    assert.strictEqual(ack.sessionId, "server-session-1");

    client.disconnect();
    await server.close();
  });

  it("rejects connect when the server sends register_rejected", async () => {
    const socketPath = shortSocketPath();
    const server = new ServerStub(socketPath);
    await server.listen();
    const acceptWait = server.waitForAccept();

    const client = new CompanionClient({
      socketPath,
      launchNonce: "stale",
      extensionVersion: "0.1.0",
      vscodeIdentity: {
        edition: "vscode",
        version: "1.94.0",
        profileName: "Default",
        profileId: "p",
        machineId: "m",
        sessionId: "s",
        processId: 1,
        windowId: "w",
      },
      currentSettings: {},
    });
    const connectPromise = client.connect();
    await acceptWait;
    while (server.received.length === 0) {
      await new Promise((r) => setTimeout(r, 5));
    }
    server.send({
      type: "register_rejected",
      protocolVersion: 1,
      id: (server.received[0] as { id: string }).id,
      reason: "invalid_nonce",
    });

    await assert.rejects(connectPromise, /register rejected: invalid_nonce/);
    await server.close();
  });

  it("dispatches apply_theme requests to the handler and echoes the id in the reply", async () => {
    const socketPath = shortSocketPath();
    const server = new ServerStub(socketPath);
    await server.listen();
    const acceptWait = server.waitForAccept();

    const client = new CompanionClient({
      socketPath,
      launchNonce: "nonce-1",
      extensionVersion: "0.1.0",
      vscodeIdentity: {
        edition: "vscode",
        version: "1.94.0",
        profileName: "Default",
        profileId: "p",
        machineId: "m",
        sessionId: "s",
        processId: 1,
        windowId: "w",
      },
      currentSettings: {},
    });

    client.onMessage((message, reply) => {
      if (message.type === "apply_theme") {
        reply({
          type: "apply_theme_ack",
          protocolVersion: 1,
          id: message.id,
          status: "applied",
          requestedSetting: message.themeName,
          effectiveSetting: message.themeName,
          overrides: [],
        });
      }
    });

    const connectPromise = client.connect();
    await acceptWait;
    while (server.received.length === 0) {
      await new Promise((r) => setTimeout(r, 5));
    }
    server.send({
      type: "register_ack",
      protocolVersion: 1,
      id: (server.received[0] as { id: string }).id,
      sessionId: "s-1",
    });
    await connectPromise;

    const applyID = randomUUID();
    server.send({
      type: "apply_theme",
      protocolVersion: 1,
      id: applyID,
      sessionId: "s-1",
      themeName: "Mocha",
      target: "global",
    });

    // Wait for the ack to arrive on the server side.
    while (server.received.length < 2) {
      await new Promise((r) => setTimeout(r, 5));
    }
    const ack = server.received[1];
    assert.strictEqual(ack.type, "apply_theme_ack");
    if (ack.type === "apply_theme_ack") {
      assert.strictEqual(ack.id, applyID);
      assert.strictEqual(ack.status, "applied");
      assert.strictEqual(ack.effectiveSetting, "Mocha");
    }

    client.disconnect();
    await server.close();
  });
});
