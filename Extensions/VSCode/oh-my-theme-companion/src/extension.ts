import * as vscode from "vscode";
import { CompanionClient, defaultRendezvousPath, readRendezvous } from "./client";
import { ThemeService } from "./themeService";
import { ApplyThemeMessage, CompanionMessage } from "./protocol";

const EXTENSION_VERSION = "0.1.0";

let activeClient: CompanionClient | undefined;

/**
 * Extension entry point.
 *
 * Reads the rendezvous file the app publishes, connects to the
 * per-user Unix-domain socket, registers, and dispatches incoming
 * `apply_theme` requests to `ThemeService`. If the rendezvous file is
 * absent (the app is not running) the extension stays dormant.
 */
export async function activate(context: vscode.ExtensionContext): Promise<void> {
  const service = new ThemeService();
  const rendezvousPath = process.env.OMT_RENDEZVOUS_PATH ?? defaultRendezvousPath();

  try {
    activeClient = await connect(rendezvousPath, service);
  } catch (error) {
    // Registration failure or missing rendezvous is expected when the
    // app is not running. Surface it in the extension log only.
    console.log(`[oh-my-theme] not connecting: ${(error as Error).message}`);
    return;
  }

  context.subscriptions.push({
    dispose: () => {
      activeClient?.disconnect();
      activeClient = undefined;
    },
  });
}

export function deactivate(): void {
  activeClient?.disconnect();
  activeClient = undefined;
}

/**
 * Read the rendezvous, open the socket, register, and wire an
 * apply_theme handler. Exported for tests that want to inject a
 * custom rendezvous path.
 */
export async function connect(rendezvousPath: string, service: ThemeService): Promise<CompanionClient> {
  const rendezvous = await readRendezvous(rendezvousPath);
  const identity = collectIdentity();
  const client = new CompanionClient({
    socketPath: rendezvous.socketPath,
    launchNonce: rendezvous.launchNonce,
    extensionVersion: EXTENSION_VERSION,
    vscodeIdentity: identity,
    currentSettings: service.snapshot(),
    protocolVersion: rendezvous.protocolVersion,
  });
  client.onMessage(makeHandler(service));
  await client.connect();
  return client;
}

function makeHandler(service: ThemeService): (message: CompanionMessage, reply: (m: CompanionMessage) => void) => Promise<void> {
  return async (message, reply) => {
    if (message.type !== "apply_theme") return;
    const ack = await service.apply(message as ApplyThemeMessage);
    reply(ack);
  };
}

function collectIdentity() {
  const env = vscode.env;
  return {
    edition: env.appName,
    version: vscode.version,
    profileName: env.appHost, // "desktop" | "web" | remote host name
    profileId: env.machineId,
    machineId: env.machineId,
    sessionId: env.sessionId,
    processId: process.pid,
    windowId: env.sessionId,
  };
}
