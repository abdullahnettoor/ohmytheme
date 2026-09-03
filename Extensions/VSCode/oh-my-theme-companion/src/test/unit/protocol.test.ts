import * as assert from "assert";
import { randomUUID } from "crypto";
import {
  CompanionMessage,
  FrameDecoder,
  MAX_BODY_SIZE,
  ProtocolError,
  decodeMessage,
  encodeFrame,
  encodeMessage,
} from "../../protocol";

describe("frame codec", () => {
  it("prefixes the JSON body with its big-endian length", () => {
    const body = Buffer.from('{"protocolVersion":1}', "utf8");
    const framed = encodeFrame(body);
    assert.strictEqual(framed.length, body.length + 4);
    assert.strictEqual(framed.readUInt32BE(0), body.length);
    assert.deepStrictEqual(framed.subarray(4), body);
  });

  it("streams a single frame from a buffered read", () => {
    const body = Buffer.from('{"protocolVersion":1}', "utf8");
    const framed = encodeFrame(body);
    const decoder = new FrameDecoder();
    decoder.append(framed);
    const decoded = decoder.nextFrame();
    assert.deepStrictEqual(decoded, body);
    assert.strictEqual(decoder.nextFrame(), undefined);
  });

  it("waits for the full body before returning a frame", () => {
    const body = Buffer.from('{"protocolVersion":1,"type":"a"}', "utf8");
    const framed = encodeFrame(body);
    const decoder = new FrameDecoder();
    decoder.append(framed.subarray(0, framed.length - 3));
    assert.strictEqual(decoder.nextFrame(), undefined);
    decoder.append(framed.subarray(framed.length - 3));
    assert.deepStrictEqual(decoder.nextFrame(), body);
  });

  it("yields consecutive frames from one buffer", () => {
    const first = Buffer.from('{"protocolVersion":1,"a":1}', "utf8");
    const second = Buffer.from('{"protocolVersion":1,"b":2}', "utf8");
    const decoder = new FrameDecoder();
    decoder.append(Buffer.concat([encodeFrame(first), encodeFrame(second)]));
    assert.deepStrictEqual(decoder.nextFrame(), first);
    assert.deepStrictEqual(decoder.nextFrame(), second);
    assert.strictEqual(decoder.nextFrame(), undefined);
  });

  it("rejects a frame larger than the body limit", () => {
    const header = Buffer.alloc(4);
    header.writeUInt32BE(MAX_BODY_SIZE + 1, 0);
    const decoder = new FrameDecoder();
    decoder.append(header);
    assert.throws(() => decoder.nextFrame(), /exceeds/);
  });
});

describe("message codec", () => {
  it("round-trips register_ack", () => {
    const message: CompanionMessage = {
      type: "register_ack",
      protocolVersion: 1,
      id: randomUUID(),
      sessionId: "s-1",
    };
    const body = Buffer.from(JSON.stringify(message), "utf8");
    const decoded = decodeMessage(body);
    assert.deepStrictEqual(decoded, message);
  });

  it("round-trips apply_theme_ack with overrides and failure", () => {
    const id = randomUUID();
    const applied: CompanionMessage = {
      type: "apply_theme_ack",
      protocolVersion: 1,
      id,
      status: "applied",
      requestedSetting: "Mocha",
      effectiveSetting: "Mocha",
      overrides: [],
    };
    const framedBody = encodeMessage(applied);
    assert.deepStrictEqual(
      decodeMessage(framedBody.subarray(4)),
      applied,
    );

    const failed: CompanionMessage = {
      type: "apply_theme_ack",
      protocolVersion: 1,
      id,
      status: "failed",
      requestedSetting: "Mocha",
      overrides: [],
      failure: { code: "update_threw", message: "boom" },
    };
    const failedBody = encodeMessage(failed);
    assert.deepStrictEqual(
      decodeMessage(failedBody.subarray(4)),
      failed,
    );
  });

  it("rejects non-JSON bodies", () => {
    assert.throws(() => decodeMessage(Buffer.from("not-json")), /valid JSON/);
  });

  it("rejects JSON that is not an object", () => {
    assert.throws(() => decodeMessage(Buffer.from("[]")), /JSON object/);
  });

  it("rejects unknown message types", () => {
    const body = Buffer.from(
      JSON.stringify({
        protocolVersion: 1,
        type: "unknown",
        id: randomUUID(),
      }),
    );
    assert.throws(() => decodeMessage(body), ProtocolError);
  });

  it("rejects missing required fields", () => {
    const body = Buffer.from(
      JSON.stringify({
        protocolVersion: 1,
        type: "apply_theme",
        id: randomUUID(),
      }),
    );
    assert.throws(() => decodeMessage(body), /missing/);
  });

  it("rejects invalid UUIDs", () => {
    const body = Buffer.from(
      JSON.stringify({
        protocolVersion: 1,
        type: "register_ack",
        id: "not-a-uuid",
        sessionId: "s",
      }),
    );
    assert.throws(() => decodeMessage(body), /UUID/);
  });
});
