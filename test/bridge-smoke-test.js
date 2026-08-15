#!/usr/bin/env node
const assert = require("node:assert/strict");
const http = require("node:http");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");
const coreDir = path.join(__dirname, "..", "src", "core");
const { describeImage } = require(path.join(coreDir, "vision-client.js"));

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
      res.on("end", () => {
        let parsed;
        try { parsed = JSON.parse(data); } catch { parsed = data; }
        resolve({ status: res.statusCode, body: parsed, headers: res.headers });
      });
    });
    req.on("error", reject);
    req.end(body);
  });
}

function startPost(port, urlPath, payload) {
  const body = JSON.stringify(payload);
  const req = http.request({
    host: "127.0.0.1",
    port,
    path: urlPath,
    method: "POST",
    headers: { "content-type": "application/json", "content-length": Buffer.byteLength(body), "x-bridge-token": "test-bridge-token" },
  }, (res) => res.resume());
  req.on("error", () => {});
  req.end(body);
  return req;
}

function startPartialPost(port, urlPath, prefix = '{"messages":') {
  const req = http.request({
    host: "127.0.0.1",
    port,
    path: urlPath,
    method: "POST",
    headers: {
      "content-type": "application/json",
      "content-length": 1000,
      "x-bridge-token": "test-bridge-token",
    },
  });
  req.on("error", () => {});
  req.write(prefix);
  return req;
}

function get(port, urlPath, token = "") {
  return new Promise((resolve, reject) => {
    const headers = token ? { "x-bridge-token": token } : {};
    http.get({ host: "127.0.0.1", port, path: urlPath, headers }, (res) => {
      res.resume();
      res.on("end", () => resolve(res.statusCode));
    }).on("error", reject);
  });
}

async function waitForHealth(port, token) {
  for (let i = 0; i < 40; i += 1) {
    try {
      if (await get(port, "/health", token) === 200) return;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("bridge did not become healthy");
}

async function waitUntil(predicate, message, timeoutMs = 3000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(message);
}

function imagePayload() {
  return {
    model: "text-model",
    messages: [{ role: "user", content: [
      { type: "image_url", image_url: { url: "data:image/png;base64,AAAA" } },
      { type: "text", text: "describe" },
    ] }],
  };
}

function assertConfigRejected(env, expectedMessage) {
  const result = spawnSync(process.execPath, [path.join(coreDir, "vision-bridge.js")], {
    env: { ...process.env, ...env },
    encoding: "utf8",
    timeout: 5000,
  });
  assert.equal(result.status, 1);
  assert.match(`${result.stdout}\n${result.stderr}`, expectedMessage);
}

async function main() {
  await assert.rejects(
    describeImage("data:image/png;base64,AAAA", {
      baseUrl: "",
      model: "test-vision-model",
      apiKey: "test-key",
    }),
    /VISION_BASE_URL is required/,
  );
  await assert.rejects(
    describeImage("data:image/png;base64,AAAA", {
      baseUrl: "https://vision.example/v1",
      model: "",
      apiKey: "test-key",
    }),
    /VISION_MODEL is required/,
  );
  const seen = [];
  let holdVision = false;
  let visionGate = Promise.resolve();
  let releaseHeldVision = () => {};
  let visionStarted = 0;
  let holdUpstream = false;
  let upstreamGate = Promise.resolve();
  let releaseHeldUpstream = () => {};
  const vision = http.createServer((req, res) => {
    req.resume();
    req.on("end", async () => {
      visionStarted += 1;
      if (holdVision) await visionGate;
      if (res.writableEnded) return;
      res.writeHead(200, {
        "content-type": "application/json",
        connection: "x-hop-by-hop, keep-alive",
        "x-hop-by-hop": "secret",
        "x-end-to-end": "preserved",
      });
      res.end(JSON.stringify({ choices: [{ message: { content: "MOCK_IMAGE_DESCRIPTION" } }] }));
    });
  });
  const upstream = http.createServer((req, res) => {
    let body = "";
    req.setEncoding("utf8");
    req.on("data", (chunk) => { body += chunk; });
    req.on("end", async () => {
      seen.push({ url: req.url, headers: req.headers, payload: JSON.parse(body) });
      if (holdUpstream) await upstreamGate;
      if (res.writableEnded) return;
      res.writeHead(200, {
        "content-type": "application/json",
        connection: "x-hop-by-hop, keep-alive",
        "x-hop-by-hop": "secret",
        "x-end-to-end": "preserved",
      });
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
  const bridge = spawn(process.execPath, [path.join(coreDir, "vision-bridge.js")], {
    env: {
      ...process.env,
      BRIDGE_PORT: String(bridgePort),
      BRIDGE_AUTH_TOKEN: "test-bridge-token",
      UPSTREAM: `http://127.0.0.1:${upstreamPort}/v1`,
      VISION_BASE_URL: `http://127.0.0.1:${visionPort}/v1`,
      VISION_MODEL: "test-vision-model",
      VISION_API_KEY: "test-key",
      VISION_TIMEOUT_MS: "2000",
      UPSTREAM_TIMEOUT_MS: "2000",
      BRIDGE_MAX_IMAGES: "8",
      BRIDGE_MAX_CONCURRENT_VISION_REQUESTS: "2",
      BRIDGE_MAX_VISION_JOBS: "16",
      BRIDGE_TOTAL_REQUEST_TIMEOUT_MS: "1200",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });

  try {
    await waitForHealth(bridgePort, "test-bridge-token");
    assert.equal(await get(bridgePort, "/health"), 401);
    const unauthorized = await post(bridgePort, "/v1/messages", { messages: [] }, "");
    assert.equal(unauthorized.status, 401);

    const anthropic = await post(bridgePort, "/v1/messages?beta=1", {
      model: "text-model",
      messages: [{ role: "user", content: [
        { type: "text", text: "describe" },
        { type: "image", source: { type: "base64", media_type: "image/png", data: "AAAA" } },
      ] }],
    }, "test-bridge-token", true);
    assert.equal(anthropic.status, 200);
    assert.equal(anthropic.headers["x-hop-by-hop"], undefined);
    assert.equal(anthropic.headers["x-end-to-end"], "preserved");

    const openAi = await post(bridgePort, "/v1/chat/completions", imagePayload());
    assert.equal(openAi.status, 200);
    const textPayload = { model: "text-model", messages: [{ role: "user", content: "text only" }] };
    await post(bridgePort, "/v1/messages", textPayload);
    const tooManyImages = {
      model: "text-model",
      messages: [{ role: "user", content: Array.from({ length: 9 }, () => ({
        type: "image_url", image_url: { url: "data:image/png;base64,AAAA" },
      })) }],
    };
    const rejectedImages = await post(bridgePort, "/v1/chat/completions", tooManyImages);
    assert.equal(rejectedImages.status, 413);
    assert.match(rejectedImages.body.error, /maximum is 8/);

    const partialRequests = Array.from({ length: 16 }, () => (
      startPartialPost(bridgePort, "/v1/chat/completions")
    ));
    await new Promise((resolve) => setTimeout(resolve, 100));
    const preBodyRejected = await post(bridgePort, "/v1/chat/completions", imagePayload());
    assert.equal(preBodyRejected.status, 429);
    partialRequests.forEach((request) => request.destroy());
    await new Promise((resolve) => setTimeout(resolve, 100));

    holdVision = true;
    visionStarted = 0;
    visionGate = new Promise((resolve) => { releaseHeldVision = resolve; });
    const first = post(bridgePort, "/v1/chat/completions", imagePayload());
    const second = post(bridgePort, "/v1/chat/completions", imagePayload());
    await waitUntil(() => visionStarted === 2, "vision concurrency did not reach 2");
    const queued = Array.from({ length: 14 }, () => post(bridgePort, "/v1/chat/completions", imagePayload()));
    await new Promise((resolve) => setTimeout(resolve, 100));
    const queueRejected = await post(bridgePort, "/v1/chat/completions", imagePayload());
    assert.equal(queueRejected.status, 429);
    assert.equal(queueRejected.headers["retry-after"], "1");
    holdVision = false;
    releaseHeldVision();
    const queuedResults = await Promise.all([first, second, ...queued]);
    assert.equal(queuedResults.every((result) => result.status === 200), true);

    holdVision = true;
    visionStarted = 0;
    visionGate = new Promise((resolve) => { releaseHeldVision = resolve; });
    const aborted = startPost(bridgePort, "/v1/chat/completions", imagePayload());
    await waitUntil(() => visionStarted === 1, "vision request did not start before abort");
    aborted.destroy();
    await new Promise((resolve) => setTimeout(resolve, 100));
    holdVision = false;
    releaseHeldVision();
    assert.equal((await post(bridgePort, "/v1/chat/completions", imagePayload())).status, 200);

    holdVision = true;
    visionStarted = 0;
    visionGate = new Promise((resolve) => { releaseHeldVision = resolve; });
    const timedOut = post(bridgePort, "/v1/chat/completions", imagePayload());
    assert.equal((await timedOut).status, 504);
    holdVision = false;
    releaseHeldVision();

    holdUpstream = true;
    upstreamGate = new Promise((resolve) => { releaseHeldUpstream = resolve; });
    const upstreamTimedOut = post(bridgePort, "/v1/chat/completions", imagePayload());
    assert.equal((await upstreamTimedOut).status, 504);
    holdUpstream = false;
    releaseHeldUpstream();

    assertConfigRejected({
      BRIDGE_PORT: "19002",
      UPSTREAM: "http://example.com/v1",
      VISION_BASE_URL: "https://vision.example/v1",
      VISION_MODEL: "test-vision-model",
      VISION_API_KEY: "test-key",
    }, /UPSTREAM must use https/);
    assertConfigRejected({
      BRIDGE_PORT: "19003",
      UPSTREAM: "http://127.0.0.1:9/v1",
      VISION_BASE_URL: "http://example.com/v1",
      VISION_MODEL: "test-vision-model",
      VISION_API_KEY: "test-key",
    }, /VISION_BASE_URL must use https/);
    assertConfigRejected({
      BRIDGE_PORT: "19004",
      UPSTREAM: "http://127.evil.example/v1",
      VISION_BASE_URL: "https://vision.example/v1",
      VISION_MODEL: "test-vision-model",
      VISION_API_KEY: "test-key",
    }, /UPSTREAM must use https/);
    assertConfigRejected({
      BRIDGE_PORT: "19005",
      UPSTREAM: "https://text.example/v1",
      VISION_BASE_URL: "",
      VISION_MODEL: "test-vision-model",
      VISION_API_KEY: "test-key",
    }, /VISION_BASE_URL is required/);
    assertConfigRejected({
      BRIDGE_PORT: "19006",
      UPSTREAM: "https://text.example/v1",
      VISION_BASE_URL: "https://vision.example/v1",
      VISION_MODEL: "",
      VISION_API_KEY: "test-key",
    }, /VISION_MODEL is required/);

    assert.equal(seen.length, 21);
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
    holdVision = false;
    releaseHeldVision();
    holdUpstream = false;
    releaseHeldUpstream();
    bridge.kill();
    await close(vision);
    await close(upstream);
  }
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exitCode = 1;
});
