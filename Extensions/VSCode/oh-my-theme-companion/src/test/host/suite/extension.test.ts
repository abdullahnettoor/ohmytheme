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
 *  - accepts inspect and guarded `apply_theme` requests;
 *  - acknowledges a guarded Undo and restores the configured global value.
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
  it("inspects, applies, and performs a guarded Undo", async function () {
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
    const originalConfiguredSetting = service.inspect().configuredSetting ?? null;
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
      const inspectID = randomUUID();
      stub.send({
        type: "inspect_theme",
        protocolVersion: 1,
        id: inspectID,
        sessionId: "s-1",
      });
      while (stub.state.received.length < 2) {
        await new Promise((r) => setTimeout(r, 20));
      }
      const inspectAck = stub.state.received[1];
      assert.strictEqual(inspectAck.type, "inspect_theme_ack");
      if (inspectAck.type !== "inspect_theme_ack") return;
      assert.strictEqual(inspectAck.id, inspectID);
      assert.strictEqual(
        inspectAck.configuredSetting ?? null,
        originalConfiguredSetting,
      );

      const themeName = pickInstalledTheme(originalConfiguredSetting);
      assert.ok(themeName, "the VS Code test host must provide an alternate installed theme");

      const applyID = randomUUID();
      stub.send({
        type: "apply_theme",
        protocolVersion: 1,
        id: applyID,
        sessionId: "s-1",
        themeName,
        expectedSetting: originalConfiguredSetting,
        target: "global",
      });

      while (stub.state.received.length < 3) {
        await new Promise((r) => setTimeout(r, 20));
      }
      const applyAck = stub.state.received[2];
      assert.strictEqual(applyAck.type, "apply_theme_ack");
      if (applyAck.type !== "apply_theme_ack") return;
      assert.strictEqual(applyAck.id, applyID);
      assert.ok(
        ["applied", "overridden"].includes(applyAck.status),
        `unexpected apply status ${applyAck.status}: ${JSON.stringify(applyAck)}`,
      );
      assert.strictEqual(applyAck.previousSetting ?? null, originalConfiguredSetting);
      assert.strictEqual(applyAck.configuredSetting, themeName);
      assert.strictEqual(
        applyAck.effectiveSetting,
        vscode.workspace.getConfiguration().get<string>("workbench.colorTheme"),
      );

      const conflictedUndoID = randomUUID();
      stub.send({
        type: "apply_theme",
        protocolVersion: 1,
        id: conflictedUndoID,
        sessionId: "s-1",
        themeName: originalConfiguredSetting,
        expectedSetting: "A stale expected theme",
        target: "global",
      });
      while (stub.state.received.length < 4) {
        await new Promise((r) => setTimeout(r, 20));
      }
      const conflictedUndoAck = stub.state.received[3];
      assert.strictEqual(conflictedUndoAck.type, "apply_theme_ack");
      if (conflictedUndoAck.type !== "apply_theme_ack") return;
      assert.strictEqual(conflictedUndoAck.status, "conflicted");
      assert.strictEqual(service.inspect().configuredSetting, themeName);

      const undoID = randomUUID();
      stub.send({
        type: "apply_theme",
        protocolVersion: 1,
        id: undoID,
        sessionId: "s-1",
        themeName: originalConfiguredSetting,
        expectedSetting: themeName,
        target: "global",
      });

      while (stub.state.received.length < 5) {
        await new Promise((r) => setTimeout(r, 20));
      }
      const undoAck = stub.state.received[4];
      assert.strictEqual(undoAck.type, "apply_theme_ack");
      if (undoAck.type !== "apply_theme_ack") return;
      assert.strictEqual(undoAck.id, undoID);
      assert.ok(
        ["applied", "overridden"].includes(undoAck.status),
        `unexpected Undo status ${undoAck.status}: ${JSON.stringify(undoAck)}`,
      );
      assert.strictEqual(undoAck.previousSetting, themeName);
      assert.strictEqual(
        undoAck.configuredSetting ?? null,
        originalConfiguredSetting,
      );
      assert.strictEqual(
        service.inspect().configuredSetting ?? null,
        originalConfiguredSetting,
      );
    } finally {
      await vscode.workspace.getConfiguration().update(
        "workbench.colorTheme",
        originalConfiguredSetting ?? undefined,
        vscode.ConfigurationTarget.Global,
      );
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
function pickInstalledTheme(excluding: string | null): string | undefined {
  for (const extension of vscode.extensions.all) {
    const themes = (extension.packageJSON as { contributes?: { themes?: Array<{ label?: string }> } })
      ?.contributes?.themes;
    if (!Array.isArray(themes)) continue;
    for (const theme of themes) {
      if (
        typeof theme?.label === "string" &&
        theme.label.length > 0 &&
        theme.label !== excluding
      ) {
        return theme.label;
      }
    }
  }
  return undefined;
}
