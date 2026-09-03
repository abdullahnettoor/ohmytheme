import { promises as fs } from "fs";
import * as net from "net";
import * as os from "os";
import * as path from "path";
import { randomUUID } from "crypto";
import {
  CURRENT_PROTOCOL_VERSION,
  CompanionMessage,
  FrameDecoder,
  ProtocolError,
  RegisterAckMessage,
  RegisterRejectedMessage,
  decodeMessage,
  encodeMessage,
} from "./protocol";

/** Rendezvous document written by the app. */
export interface Rendezvous {
  socketPath: string;
  launchId: string;
  launchNonce: string;
  protocolVersion: number;
  supportedProtocolVersions: number[];
}

/** Default location of the app's rendezvous file. */
export function defaultRendezvousPath(): string {
  return path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "OhMyTheme",
    "companion",
    "rendezvous.json",
  );
}

export async function readRendezvous(filePath: string): Promise<Rendezvous> {
  const raw = await fs.readFile(filePath, "utf8");
  const parsed = JSON.parse(raw) as Partial<Rendezvous>;
  if (
    typeof parsed.socketPath !== "string" ||
    typeof parsed.launchId !== "string" ||
    typeof parsed.launchNonce !== "string" ||
    typeof parsed.protocolVersion !== "number" ||
    !Array.isArray(parsed.supportedProtocolVersions)
  ) {
    throw new Error(`Rendezvous file ${filePath} is missing required fields`);
  }
  return {
    socketPath: parsed.socketPath,
    launchId: parsed.launchId,
    launchNonce: parsed.launchNonce,
    protocolVersion: parsed.protocolVersion,
    supportedProtocolVersions: parsed.supportedProtocolVersions,
  };
}

// ---------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------

/** Handler that turns an incoming server message into an outgoing reply. */
export type MessageHandler = (
  message: CompanionMessage,
  reply: (message: CompanionMessage) => void,
) => Promise<void> | void;

export interface CompanionClientOptions {
  socketPath: string;
  launchNonce: string;
  extensionVersion: string;
  vscodeIdentity: {
    edition: string;
    version: string;
    profileName: string;
    profileId: string;
    machineId: string;
    sessionId: string;
    processId: number;
    windowId: string;
  };
  currentSettings: Record<string, string>;
  capabilities?: string[];
  protocolVersion?: number;
  registerTimeoutMs?: number;
}

/**
 * Connects to the app's Unix-domain socket, registers, and dispatches
 * incoming apply_theme requests to the caller-supplied handler.
 *
 * The client is single-connection: it does not automatically
 * reconnect. Callers manage retry policy externally so the extension
 * can surface repeated failures explicitly.
 */
export class CompanionClient {
  private socket?: net.Socket;
  private decoder = new FrameDecoder();
  private registered = false;
  private registerResolvers?: {
    resolve: (ack: RegisterAckMessage) => void;
    reject: (error: Error) => void;
  };
  private handler: MessageHandler = () => undefined;

  constructor(private readonly options: CompanionClientOptions) {}

  onMessage(handler: MessageHandler): void {
    this.handler = handler;
  }

  async connect(): Promise<RegisterAckMessage> {
    const socket = net.createConnection({ path: this.options.socketPath });
    this.socket = socket;

    return new Promise<RegisterAckMessage>((resolve, reject) => {
      const cleanup = () => {
        socket.removeListener("connect", onConnect);
        socket.removeListener("error", onError);
      };
      const onError = (err: Error) => {
        cleanup();
        reject(err);
      };
      const onConnect = () => {
        cleanup();
        this.registerResolvers = { resolve, reject };
        socket.on("data", (chunk) => this.onData(chunk));
        socket.on("close", () => this.onClose());
        socket.on("error", (err) => this.onError(err));
        this.sendRegister().catch(reject);
        setTimeout(() => {
          if (!this.registered) {
            reject(new Error("register timed out"));
            socket.end();
          }
        }, this.options.registerTimeoutMs ?? 5_000);
      };
      socket.once("connect", onConnect);
      socket.once("error", onError);
    });
  }

  disconnect(): void {
    this.socket?.end();
    this.socket = undefined;
    this.registered = false;
  }

  send(message: CompanionMessage): void {
    if (!this.socket) throw new Error("client is not connected");
    this.socket.write(encodeMessage(message));
  }

  // ---------------------------------------------------------------

  private async sendRegister(): Promise<void> {
    const register: CompanionMessage = {
      type: "register",
      protocolVersion: this.options.protocolVersion ?? CURRENT_PROTOCOL_VERSION,
      id: randomUUID(),
      launchNonce: this.options.launchNonce,
      extensionVersion: this.options.extensionVersion,
      vscode: this.options.vscodeIdentity,
      capabilities: this.options.capabilities ?? ["colorTheme"],
      currentSettings: this.options.currentSettings,
    };
    this.send(register);
  }

  private onData(chunk: Buffer): void {
    this.decoder.append(chunk);
    while (true) {
      let body: Buffer | undefined;
      try {
        body = this.decoder.nextFrame();
      } catch (error) {
        this.disconnect();
        this.registerResolvers?.reject(error instanceof Error ? error : new Error(String(error)));
        return;
      }
      if (!body) return;

      let message: CompanionMessage;
      try {
        message = decodeMessage(body);
      } catch (error) {
        if (error instanceof ProtocolError) {
          this.send({
            type: "protocol_error",
            protocolVersion: CURRENT_PROTOCOL_VERSION,
            id: randomUUID(),
            code: error.code,
            message: error.message,
          });
        }
        this.disconnect();
        return;
      }
      this.dispatch(message);
    }
  }

  private dispatch(message: CompanionMessage): void {
    switch (message.type) {
      case "register_ack":
        this.registered = true;
        this.registerResolvers?.resolve(message);
        this.registerResolvers = undefined;
        return;
      case "register_rejected":
        this.registerResolvers?.reject(
          new RegisterRejected(message),
        );
        this.registerResolvers = undefined;
        this.disconnect();
        return;
      default:
        void this.handler(message, (reply) => this.send(reply));
    }
  }

  private onClose(): void {
    this.registered = false;
    this.socket = undefined;
    if (this.registerResolvers) {
      this.registerResolvers.reject(new Error("socket closed before register_ack"));
      this.registerResolvers = undefined;
    }
  }

  private onError(err: Error): void {
    this.registerResolvers?.reject(err);
    this.registerResolvers = undefined;
  }
}

/** Thrown when the server rejects registration; carries the reason. */
export class RegisterRejected extends Error {
  constructor(public readonly message_: RegisterRejectedMessage) {
    super(`register rejected: ${message_.reason}`);
    this.name = "RegisterRejected";
  }
}
