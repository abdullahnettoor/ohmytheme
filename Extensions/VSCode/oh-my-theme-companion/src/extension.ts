import * as vscode from "vscode";
import { CompanionClient, defaultRendezvousPath, readRendezvous } from "./client";
import { ThemeService } from "./themeService";
import { ApplyThemeMessage, CompanionMessage } from "./protocol";

const EXTENSION_VERSION = "0.1.0";

let activeClient: CompanionClient | undefined;
let reconnectTimer: NodeJS.Timeout | undefined;
let connectionAttemptInFlight = false;
let extensionActive = false;

/**
 * Extension entry point.
 *
 * Reads the rendezvous file the app publishes, connects to the
 * per-user Unix-domain socket, registers, and dispatches incoming
 * `apply_theme` requests to `ThemeService`. If the rendezvous file is
 * absent (the app is not running) the extension stays dormant.
 */
export async function activate(context: vscode.ExtensionContext): Promise<void> {
  extensionActive = true;
  const service = new ThemeService();
  const rendezvousPath = process.env.OMT_RENDEZVOUS_PATH ?? defaultRendezvousPath();

  const attemptConnection = async () => {
    if (!extensionActive || connectionAttemptInFlight || activeClient?.isRegistered) return;
    connectionAttemptInFlight = true;
    try {
      const client = await connect(rendezvousPath, service, context);
      client.onDisconnect(() => {
        if (activeClient === client) activeClient = undefined;
      });
      if (!extensionActive) {
        client.disconnect();
        return;
      }
      activeClient = client;
    } catch (error) {
      // Missing rendezvous is normal while the app is not running. The timer
      // retries so an open VS Code window follows a later app launch/relaunch.
      console.log(`[oh-my-theme] not connecting: ${(error as Error).message}`);
    } finally {
      connectionAttemptInFlight = false;
    }
  };

  await attemptConnection();
  reconnectTimer = setInterval(() => void attemptConnection(), 1_000);
  context.subscriptions.push({
    dispose: () => {
      extensionActive = false;
      if (reconnectTimer) clearInterval(reconnectTimer);
      reconnectTimer = undefined;
      activeClient?.disconnect();
      activeClient = undefined;
    },
  });
}

export function deactivate(): void {
  extensionActive = false;
  if (reconnectTimer) clearInterval(reconnectTimer);
  reconnectTimer = undefined;
  activeClient?.disconnect();
  activeClient = undefined;
}

/**
 * Read the rendezvous, open the socket, register, and wire an
 * apply_theme handler. Exported for tests that want to inject a
 * custom rendezvous path.
 */
export async function connect(
  rendezvousPath: string,
  service: ThemeService,
  context?: vscode.ExtensionContext,
): Promise<CompanionClient> {
  const rendezvous = await readRendezvous(rendezvousPath);
  const identity = collectIdentity(context);
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

function collectIdentity(context?: vscode.ExtensionContext) {
  const env = vscode.env;
  // VS Code's stable Extension API does not expose the active profile name or id.
  // The companion therefore leaves the name empty and uses its profile-scoped global
  // storage URI as an opaque identity. VS Code also does not expose a native window
  // handle, so `env.sessionId` is the documented per-window-session identity.
  return {
    edition: mapEdition(env.appName),
    version: vscode.version,
    profileName: "",
    profileId: context?.globalStorageUri.toString() ?? "",
    machineId: env.machineId,
    sessionId: env.sessionId,
    processId: process.pid,
    windowId: env.sessionId,
  };
}

/**
 * Map `vscode.env.appName` into the closed `edition` enum defined by
 * the wire protocol. Unknown editions fall through to `"other"`.
 */
function mapEdition(
  appName: string,
): "code-oss" | "vscode" | "insiders" | "cursor" | "other" {
  const normalized = appName.toLowerCase();
  if (normalized.includes("insider")) return "insiders";
  if (normalized.includes("cursor")) return "cursor";
  if (normalized.includes("oss")) return "code-oss";
  if (normalized.includes("visual studio code") || normalized === "code") {
    return "vscode";
  }
  return "other";
}
