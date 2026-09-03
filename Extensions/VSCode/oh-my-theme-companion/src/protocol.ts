/**
 * TypeScript codec for the Oh My Theme companion wire protocol.
 *
 * This file mirrors the Swift codec in
 * `Packages/OhMyThemeKit/Sources/PlatformClients/VSCodeCompanionProtocol.swift`.
 * Both sides must accept the same wire messages, so any change here
 * MUST be matched on the Swift side and vice versa. The canonical
 * specification is `docs/architecture/vscode-companion-protocol.md`.
 */

export const CURRENT_PROTOCOL_VERSION = 1;
export const SUPPORTED_PROTOCOL_VERSIONS: readonly number[] = [1];
export const MAX_BODY_SIZE = 65_536;

// ---------------------------------------------------------------------
// Message types
// ---------------------------------------------------------------------

export type CompanionMessageType =
  | "register"
  | "register_ack"
  | "register_rejected"
  | "inspect_theme"
  | "inspect_theme_ack"
  | "apply_theme"
  | "apply_theme_ack"
  | "protocol_error";

export type RegisterRejectionReason =
  | "unsupported_protocol"
  | "invalid_nonce"
  | "duplicate_registration"
  | "missing_capability"
  | "unauthenticated_peer";

export type ApplyTarget = "global";

export type ApplyStatus =
  | "applied"
  | "overridden"
  | "unsupported_theme"
  | "conflicted"
  | "failed";

export type OverrideScope = "workspace" | "workspaceFolder" | "remote";

export type ProtocolErrorCode =
  | "malformed_frame"
  | "unsupported_type"
  | "unsupported_protocol_version"
  | "duplicate_request_id"
  | "unexpected_message"
  | "missing_required_field"
  | "not_registered";

export interface VSCodeIdentity {
  edition: string;
  version: string;
  profileName: string;
  profileId: string;
  machineId: string;
  sessionId: string;
  processId: number;
  windowId: string;
}

export interface RegisterMessage {
  type: "register";
  protocolVersion: number;
  id: string;
  launchNonce: string;
  extensionVersion: string;
  vscode: VSCodeIdentity;
  capabilities: string[];
  currentSettings: Record<string, string>;
}

export interface RegisterAckMessage {
  type: "register_ack";
  protocolVersion: number;
  id: string;
  sessionId: string;
}

export interface RegisterRejectedMessage {
  type: "register_rejected";
  protocolVersion: number;
  id: string;
  reason: RegisterRejectionReason;
}

export interface InspectThemeMessage {
  type: "inspect_theme";
  protocolVersion: number;
  id: string;
  sessionId: string;
}

export interface ApplyThemeMessage {
  type: "apply_theme";
  protocolVersion: number;
  id: string;
  sessionId: string;
  themeName: string | null;
  expectedSetting: string | null;
  target: ApplyTarget;
}

export interface OverrideEntry {
  scope: OverrideScope;
  folder?: string;
  value: string;
}

export interface ApplyFailure {
  code: string;
  message: string;
}

export interface InspectThemeAckMessage {
  type: "inspect_theme_ack";
  protocolVersion: number;
  id: string;
  configuredSetting?: string | null;
  effectiveSetting?: string | null;
  overrides: OverrideEntry[];
}

export interface ApplyThemeAckMessage {
  type: "apply_theme_ack";
  protocolVersion: number;
  id: string;
  status: ApplyStatus;
  requestedSetting: string | null;
  previousSetting?: string | null;
  configuredSetting?: string | null;
  effectiveSetting?: string | null;
  overrides: OverrideEntry[];
  failure?: ApplyFailure;
}

export interface ProtocolErrorMessage {
  type: "protocol_error";
  protocolVersion: number;
  id: string;
  requestId?: string;
  code: ProtocolErrorCode;
  message: string;
}

export type CompanionMessage =
  | RegisterMessage
  | RegisterAckMessage
  | RegisterRejectedMessage
  | InspectThemeMessage
  | InspectThemeAckMessage
  | ApplyThemeMessage
  | ApplyThemeAckMessage
  | ProtocolErrorMessage;

// ---------------------------------------------------------------------
// Framing
// ---------------------------------------------------------------------

/** Prefix a JSON body with its 32-bit big-endian length. */
export function encodeFrame(body: Buffer): Buffer {
  if (body.length > MAX_BODY_SIZE) {
    throw new Error(
      `Body of ${body.length} bytes exceeds the ${MAX_BODY_SIZE}-byte limit`,
    );
  }
  const header = Buffer.alloc(4);
  header.writeUInt32BE(body.length, 0);
  return Buffer.concat([header, body]);
}

/**
 * Streaming frame decoder. Callers feed bytes into `append` and drain
 * complete bodies via `nextFrame`. `nextFrame` returns `undefined`
 * when more bytes are needed and throws when a frame is larger than
 * `MAX_BODY_SIZE`.
 */
export class FrameDecoder {
  private buffer: Buffer = Buffer.alloc(0);

  append(bytes: Buffer): void {
    this.buffer = this.buffer.length === 0 ? bytes : Buffer.concat([this.buffer, bytes]);
  }

  nextFrame(): Buffer | undefined {
    if (this.buffer.length < 4) return undefined;
    const length = this.buffer.readUInt32BE(0);
    if (length > MAX_BODY_SIZE) {
      throw new Error(
        `Incoming frame of ${length} bytes exceeds the ${MAX_BODY_SIZE}-byte limit`,
      );
    }
    if (this.buffer.length < 4 + length) return undefined;
    const body = this.buffer.subarray(4, 4 + length);
    this.buffer = this.buffer.subarray(4 + length);
    // subarray shares memory; copy so subsequent mutation of the
    // underlying pool cannot corrupt the returned body.
    return Buffer.from(body);
  }
}

// ---------------------------------------------------------------------
// Message codec
// ---------------------------------------------------------------------

export class ProtocolError extends Error {
  constructor(
    public readonly code: ProtocolErrorCode,
    message: string,
  ) {
    super(message);
    this.name = "ProtocolError";
  }
}

const UUID_PATTERN =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

function requireField<T>(object: Record<string, unknown>, key: string, guard: (v: unknown) => v is T): T {
  const value = object[key];
  if (value === undefined) {
    throw new ProtocolError("missing_required_field", `Required field '${key}' is missing.`);
  }
  if (!guard(value)) {
    throw new ProtocolError("malformed_frame", `Field '${key}' has an unexpected type.`);
  }
  return value;
}

const isString = (v: unknown): v is string => typeof v === "string";
const isNullableString = (v: unknown): v is string | null => v === null || isString(v);
const isNumber = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const isObject = (v: unknown): v is Record<string, unknown> =>
  typeof v === "object" && v !== null && !Array.isArray(v);
const isStringArray = (v: unknown): v is string[] =>
  Array.isArray(v) && v.every((entry) => typeof entry === "string");
const isStringRecord = (v: unknown): v is Record<string, string> =>
  isObject(v) && Object.values(v).every((entry) => typeof entry === "string");

function requireEnum<T extends string>(
  object: Record<string, unknown>,
  key: string,
  values: readonly T[],
): T {
  const value = requireField(object, key, isString);
  if (!values.includes(value as T)) {
    throw new ProtocolError("malformed_frame", `Field '${key}' has an unsupported value.`);
  }
  return value as T;
}

function optionalNullableString(
  object: Record<string, unknown>,
  key: string,
): string | null | undefined {
  const value = object[key];
  if (value === undefined) return undefined;
  if (!isNullableString(value)) {
    throw new ProtocolError("malformed_frame", `Field '${key}' has an unexpected type.`);
  }
  return value;
}

function requireUUID(object: Record<string, unknown>, key: string): string {
  const raw = requireField(object, key, isString);
  if (!UUID_PATTERN.test(raw)) {
    throw new ProtocolError("malformed_frame", `Field '${key}' is not a valid UUID.`);
  }
  return raw;
}

export function encodeMessage(message: CompanionMessage): Buffer {
  const body = Buffer.from(JSON.stringify(message), "utf8");
  return encodeFrame(body);
}

export function decodeMessage(body: Buffer): CompanionMessage {
  let raw: unknown;
  try {
    raw = JSON.parse(body.toString("utf8"));
  } catch {
    throw new ProtocolError("malformed_frame", "Frame body is not valid JSON.");
  }
  if (!isObject(raw)) {
    throw new ProtocolError("malformed_frame", "Frame body is not a JSON object.");
  }

  const protocolVersion = requireField(raw, "protocolVersion", isNumber);
  const type = requireField(raw, "type", isString) as CompanionMessageType;

  const isKnownType = (
    [
      "register",
      "register_ack",
      "register_rejected",
      "inspect_theme",
      "inspect_theme_ack",
      "apply_theme",
      "apply_theme_ack",
      "protocol_error",
    ] as const
  ).includes(type as never);
  if (!isKnownType) {
    throw new ProtocolError("unsupported_type", `Message type '${type}' is not supported.`);
  }

  const id = requireUUID(raw, "id");

  switch (type) {
    case "register":
      return decodeRegister(raw, protocolVersion, id);
    case "register_ack":
      return {
        type,
        protocolVersion,
        id,
        sessionId: requireField(raw, "sessionId", isString),
      };
    case "register_rejected": {
      const reason = requireEnum<RegisterRejectionReason>(raw, "reason", [
        "unsupported_protocol",
        "invalid_nonce",
        "duplicate_registration",
        "missing_capability",
        "unauthenticated_peer",
      ]);
      return { type, protocolVersion, id, reason };
    }
    case "inspect_theme":
      return {
        type,
        protocolVersion,
        id,
        sessionId: requireField(raw, "sessionId", isString),
      };
    case "inspect_theme_ack":
      return decodeInspectAck(raw, protocolVersion, id);
    case "apply_theme":
      return {
        type,
        protocolVersion,
        id,
        sessionId: requireField(raw, "sessionId", isString),
        themeName: requireField(raw, "themeName", isNullableString),
        expectedSetting: requireField(raw, "expectedSetting", isNullableString),
        target: requireEnum<ApplyTarget>(raw, "target", ["global"]),
      };
    case "apply_theme_ack":
      return decodeApplyAck(raw, protocolVersion, id);
    case "protocol_error": {
      const code = requireEnum<ProtocolErrorCode>(raw, "code", [
        "malformed_frame",
        "unsupported_type",
        "unsupported_protocol_version",
        "duplicate_request_id",
        "unexpected_message",
        "missing_required_field",
        "not_registered",
      ]);
      const requestId = raw.requestId;
      if (requestId !== undefined && !(isString(requestId) && UUID_PATTERN.test(requestId))) {
        throw new ProtocolError("malformed_frame", "Field 'requestId' is not a valid UUID.");
      }
      return {
        type,
        protocolVersion,
        id,
        ...(isString(requestId) ? { requestId } : {}),
        code,
        message: requireField(raw, "message", isString),
      };
    }
  }
}

function decodeRegister(raw: Record<string, unknown>, protocolVersion: number, id: string): RegisterMessage {
  const vscodeRaw = requireField(raw, "vscode", isObject);
  const vscode: VSCodeIdentity = {
    edition: requireField(vscodeRaw, "edition", isString),
    version: requireField(vscodeRaw, "version", isString),
    profileName: requireField(vscodeRaw, "profileName", isString),
    profileId: requireField(vscodeRaw, "profileId", isString),
    machineId: requireField(vscodeRaw, "machineId", isString),
    sessionId: requireField(vscodeRaw, "sessionId", isString),
    processId: requireField(vscodeRaw, "processId", isNumber),
    windowId: requireField(vscodeRaw, "windowId", isString),
  };
  return {
    type: "register",
    protocolVersion,
    id,
    launchNonce: requireField(raw, "launchNonce", isString),
    extensionVersion: requireField(raw, "extensionVersion", isString),
    vscode,
    capabilities: requireField(raw, "capabilities", isStringArray),
    currentSettings: requireField(raw, "currentSettings", isStringRecord),
  };
}

function decodeInspectAck(
  raw: Record<string, unknown>,
  protocolVersion: number,
  id: string,
): InspectThemeAckMessage {
  const configuredSetting = optionalNullableString(raw, "configuredSetting");
  const effectiveSetting = optionalNullableString(raw, "effectiveSetting");
  return {
    type: "inspect_theme_ack",
    protocolVersion,
    id,
    ...(configuredSetting !== undefined ? { configuredSetting } : {}),
    ...(effectiveSetting !== undefined ? { effectiveSetting } : {}),
    overrides: decodeOverrides(raw),
  };
}

function decodeApplyAck(
  raw: Record<string, unknown>,
  protocolVersion: number,
  id: string,
): ApplyThemeAckMessage {
  const status = requireEnum<ApplyStatus>(raw, "status", [
    "applied",
    "overridden",
    "unsupported_theme",
    "conflicted",
    "failed",
  ]);
  const requestedSetting = requireField(raw, "requestedSetting", isNullableString);
  const previousSetting = optionalNullableString(raw, "previousSetting");
  const configuredSetting = optionalNullableString(raw, "configuredSetting");
  const effectiveSetting = optionalNullableString(raw, "effectiveSetting");

  const failureRaw = raw.failure;
  let failure: ApplyFailure | undefined;
  if (failureRaw !== undefined) {
    if (!isObject(failureRaw)) {
      throw new ProtocolError("malformed_frame", "Field 'failure' must be an object.");
    }
    failure = {
      code: requireField(failureRaw, "code", isString),
      message: requireField(failureRaw, "message", isString),
    };
  }
  if (status === "failed" && failure === undefined) {
    throw new ProtocolError(
      "missing_required_field",
      "Required field 'failure' is missing for a failed apply acknowledgement.",
    );
  }
  if (status !== "failed" && failure !== undefined) {
    throw new ProtocolError(
      "malformed_frame",
      "Field 'failure' is only valid for a failed apply acknowledgement.",
    );
  }

  return {
    type: "apply_theme_ack",
    protocolVersion,
    id,
    status,
    requestedSetting,
    ...(previousSetting !== undefined ? { previousSetting } : {}),
    ...(configuredSetting !== undefined ? { configuredSetting } : {}),
    ...(effectiveSetting !== undefined ? { effectiveSetting } : {}),
    overrides: decodeOverrides(raw),
    ...(failure !== undefined ? { failure } : {}),
  };
}

function decodeOverrides(raw: Record<string, unknown>): OverrideEntry[] {
  const overridesRaw = raw.overrides;
  if (overridesRaw === undefined) {
    throw new ProtocolError("missing_required_field", "Required field 'overrides' is missing.");
  }
  if (!Array.isArray(overridesRaw)) {
    throw new ProtocolError("malformed_frame", "Field 'overrides' must be an array.");
  }

  return overridesRaw.map((entry) => {
    if (!isObject(entry)) {
      throw new ProtocolError("malformed_frame", "Override entry must be an object.");
    }
    const folder = entry.folder;
    if (folder !== undefined && !isString(folder)) {
      throw new ProtocolError("malformed_frame", "Field 'folder' has an unexpected type.");
    }
    return {
      scope: requireEnum<OverrideScope>(entry, "scope", ["workspace", "workspaceFolder", "remote"]),
      ...(folder !== undefined ? { folder } : {}),
      value: requireField(entry, "value", isString),
    };
  });
}
