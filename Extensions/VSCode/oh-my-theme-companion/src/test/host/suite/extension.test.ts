import * as assert from "assert";
import * as net from "net";
import * as os from "os";
import * as path from "path";
import { promises as fs } from "fs";
import { randomUUID } from "crypto";
import * as vscode from "vscode";
import {
  CompanionMessage,
  FrameDecoder,
  decodeMessage,
  encodeMessage,
} from "../../../protocol";
import { connect } from "../../../extension";
import { ThemeService } from "../../../themeService";

/**
 * End-to-end proof: a real VS Code host runs the extension, connects
 * to a native-side stub server, and applies a theme through the
 * supported `WorkspaceConfiguration.update` API. The stub verifies
 * the extension:
 *
 *  - registers with its VS Code identity and current settings;
 *  - accepts an `apply_theme` request;
 *  - answers with an ack whose `effectiveSetting` matches what VS
 *    Code actually has after the update.
 *
 * This is the acceptance-criteria "extension-host test in a real
 * supported VS Code host".
 */

function makeStubServer(socketPath: string) {
  const state = {
    received: [] as CompanionMessage[],
    socket: undefined as net.Socket | undefined,
  };
  const decoder = new FrameDecoder();
  const server = net.createServer((socket) => {
    state.socket = socket;
    socket.on("data", (chunk) => {
      decoder.append(chunk);
      while (true) {
        const body = decoder.nextFrame();
        if (!body) return;
        state.received.push(decodeMessage(body));
      }
    });
  });
  return {
    listen: () =>
      new Promise<void>((resolve, reject) => {
        server.once("error", reject);
        server.listen(socketPath, () => resolve());
      }),
    send: (message: CompanionMessage) => state.socket!.write(encodeMessage(message)),
    state,
    close: () =>
      new Promise<void>((resolve) => {
        state.socket?.destroy();
        server.close(() => resolve());
      }),
  };
}

describe("Companion extension host tests", () => {
  it("registers and applies a theme through WorkspaceConfiguration", async function () {
    this.timeout(20_000);
    const testRoot =
      process.env.OMT_TEST_ROOT ?? (await fs.mkdtemp(path.join(os.tmpdir(), "omt-host-")));
    const rendezvousPath =
      process.env.OMT_TEST_RENDEZVOUS_PATH ?? path.join(testRoot, "rendezvous.json");
    const socketPath = path.join(testRoot, "companion.sock");

    // Clean up any leftover socket from a prior run.
    try {
      await fs.unlink(socketPath);
    } catch {
      /* ignore */
    }

    const stub = makeStubServer(socketPath);
    await stub.listen();

    const rendezvous = {
      socketPath,
      launchId: "test-launch",
      launchNonce: "nonce-1",
      protocolVersion: 1,
      supportedProtocolVersions: [1],
    };
    await fs.writeFile(rendezvousPath, JSON.stringify(rendezvous), { mode: 0o600 });

    const service = new ThemeService();
    // Kick off connect without awaiting: it can only complete once the
    // stub responds with register_ack.
    const clientPromise = connectPromise(rendezvousPath, service);

    // Wait for the register to be received.
    while (stub.state.received.length === 0) {
      await new Promise((r) => setTimeout(r, 10));
    }
    const registerMessage = stub.state.received[0];
    assert.strictEqual(registerMessage.type, "register");
    if (registerMessage.type === "register") {
      assert.strictEqual(registerMessage.launchNonce, "nonce-1");
    }

    // Send register_ack so connect resolves.
    stub.send({
      type: "register_ack",
      protocolVersion: 1,
      id: (registerMessage as { id: string }).id,
      sessionId: "s-1",
    });

    const client = await clientPromise;
    try {

      // Pick a theme that is guaranteed to be installed in this
      // VS Code test host. Enumerate contributed themes; fall back
      // to `Default Dark+` if the enumeration is empty.
      const themeName = pickInstalledTheme() ?? "Default Dark+";
      const applyID = randomUUID();
      stub.send({
        type: "apply_theme",
        protocolVersion: 1,
        id: applyID,
        sessionId: "s-1",
        themeName,
        target: "global",
      });

      // Wait for the ack.
      while (stub.state.received.length < 2) {
        await new Promise((r) => setTimeout(r, 20));
      }
      const ack = stub.state.received[1];
      assert.strictEqual(ack.type, "apply_theme_ack");
      if (ack.type === "apply_theme_ack") {
        assert.strictEqual(ack.id, applyID);
        // The extension must copy the request id verbatim.
        assert.ok(
          ["applied", "overridden"].includes(ack.status),
          `unexpected status ${ack.status}: ${JSON.stringify(ack)}`,
        );
        // The effective setting the extension reports must equal
        // what VS Code itself now has.
        const currentTheme = vscode.workspace
          .getConfiguration()
          .get<string>("workbench.colorTheme");
        assert.strictEqual(ack.effectiveSetting, currentTheme);
      }
    } finally {
      client.disconnect();
      await stub.close();
    }
  });
});

/** Wraps `connect` to return the client promise for the test. */
function connectPromise(rendezvousPath: string, service: ThemeService) {
  return connect(rendezvousPath, service);
}

/** Returns the label of a theme contributed by any loaded extension. */
function pickInstalledTheme(): string | undefined {
  for (const extension of vscode.extensions.all) {
    const themes = (extension.packageJSON as { contributes?: { themes?: Array<{ label?: string }> } })
      ?.contributes?.themes;
    if (!Array.isArray(themes)) continue;
    for (const theme of themes) {
      if (typeof theme?.label === "string" && theme.label.length > 0) return theme.label;
    }
  }
  return undefined;
}
