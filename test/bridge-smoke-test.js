#!/usr/bin/env node
const assert = require("node:assert/strict");
const http = require("node:http");
const path = require("node:path");
const { spawn } = require("node:child_process");

function listen(server) {
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server.address().port)));
}

function close(server) {
  return new Promise((resolve) => server.close(resolve));
}

function post(port, urlPath, payload, token = "test-bridge-token", chunked = false) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify(payload);
    const headers = { "content-type": "application/json" };
    if (token) headers["x-bridge-token"] = token;
    if (!chunked) headers["content-length"] = Buffer.byteLength(body);
    const req = http.request({ host: "127.0.0.1", port, path: urlPath, method: "POST", headers }, (res) => {
      let data = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => { data += chunk; });
      res.on("end", () => resolve({ status: res.statusCode, body: JSON.parse(data) }));
    });
    req.on("error", reject);
    req.end(body);
  });
}

function get(port, urlPath) {
  return new Promise((resolve, reject) => {
    http.get({ host: "127.0.0.1", port, path: urlPath }, (res) => {
      res.resume();
      res.on("end", () => resolve(res.statusCode));
    }).on("error", reject);
  });
}

async function waitForHealth(port) {
  for (let i = 0; i < 40; i += 1) {
    try {
      if (await get(port, "/health") === 200) return;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("bridge did not become healthy");
}

async function main() {
  const seen = [];
  const vision = http.createServer((req, res) => {
    req.resume();
    req.on("end", () => {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ choices: [{ message: { content: "MOCK_IMAGE_DESCRIPTION" } }] }));
    });
  });
  const upstream = http.createServer((req, res) => {
    let body = "";
    req.setEncoding("utf8");
    req.on("data", (chunk) => { body += chunk; });
    req.on("end", () => {
      seen.push({ url: req.url, headers: req.headers, payload: JSON.parse(body) });
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true }));
    });
  });

  const visionPort = await listen(vision);
  const upstreamPort = await listen(upstream);
  const bridgePort = await new Promise((resolve) => {
    const probe = http.createServer();
    probe.listen(0, "127.0.0.1", () => {
      const port = probe.address().port;
      probe.close(() => resolve(port));
    });
  });
  const bridge = spawn(process.execPath, [path.join(__dirname, "..", "src", "vision-bridge.js")], {
    env: {
      ...process.env,
      BRIDGE_PORT: String(bridgePort),
      BRIDGE_AUTH_TOKEN: "test-bridge-token",
      UPSTREAM: `http://127.0.0.1:${upstreamPort}/v1`,
      VISION_BASE_URL: `http://127.0.0.1:${visionPort}/v1`,
      VISION_API_KEY: "test-key",
      VISION_TIMEOUT_MS: "2000",
      UPSTREAM_TIMEOUT_MS: "2000",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });

  try {
    await waitForHealth(bridgePort);
    const unauthorized = await post(bridgePort, "/v1/messages", { messages: [] }, "");
    assert.equal(unauthorized.status, 401);
    await post(bridgePort, "/v1/messages?beta=1", {
      model: "text-model",
      messages: [{ role: "user", content: [
        { type: "text", text: "describe" },
        { type: "image", source: { type: "base64", media_type: "image/png", data: "AAAA" } },
      ] }],
    }, "test-bridge-token", true);
    await post(bridgePort, "/v1/chat/completions", {
      model: "text-model",
      messages: [{ role: "user", content: [
        { type: "image_url", image_url: { url: "data:image/png;base64,AAAA" } },
        { type: "text", text: "describe" },
      ] }],
    });
    const textPayload = { model: "text-model", messages: [{ role: "user", content: "text only" }] };
    await post(bridgePort, "/v1/messages", textPayload);

    assert.equal(seen.length, 3);
    assert.equal(seen[0].url, "/v1/messages?beta=1");
    assert.equal(seen[0].headers["transfer-encoding"], undefined);
    assert.equal(seen[0].headers["x-bridge-token"], undefined);
    assert.ok(Number(seen[0].headers["content-length"]) > 0);
    for (const item of seen.slice(0, 2)) {
      const blocks = item.payload.messages[0].content;
      assert.equal(blocks.some((block) => ["image", "image_url"].includes(block.type)), false);
      assert.equal(blocks.some((block) => block.text?.includes("MOCK_IMAGE_DESCRIPTION")), true);
    }
    assert.deepEqual(seen[2].payload, textPayload);
    console.log("bridge smoke test: PASS");
  } finally {
    bridge.kill();
    await close(vision);
    await close(upstream);
  }
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exitCode = 1;
});
