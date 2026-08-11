#!/usr/bin/env node
/** Convert image blocks to text before forwarding to a text-only model. */
const crypto = require("node:crypto");
const http = require("node:http");
const https = require("node:https");
const { describeImage, imageUrlFromBlock } = require("./vision-client");

const HOST = process.env.BRIDGE_HOST || "127.0.0.1";
const PORT = Number(process.env.BRIDGE_PORT || 15720);
const UPSTREAM = process.env.UPSTREAM || "";
const BRIDGE_AUTH_TOKEN = process.env.BRIDGE_AUTH_TOKEN || "";
const VISION_MODEL = process.env.VISION_MODEL || "step-3.7-flash";
const VISION_PROMPT = process.env.VISION_PROMPT
  || "用简短中文准确描述图片内容；如有文字，优先完整抄录与问题最相关的文字。";
const MAX_BODY_BYTES = Number(process.env.BRIDGE_MAX_BODY_BYTES || 25 * 1024 * 1024);
const UPSTREAM_TIMEOUT_MS = Number(process.env.UPSTREAM_TIMEOUT_MS || 120000);

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

function pathOnly(urlPath) {
  return (urlPath || "/").split("?", 1)[0];
}

function isSupportedPath(urlPath) {
  return /^\/(?:v1\/)?(?:messages|chat\/completions)\/?$/.test(pathOnly(urlPath));
}

function hasImages(payload) {
  return Array.isArray(payload?.messages)
    && payload.messages.some((message) => Array.isArray(message?.content)
      && message.content.some((block) => Boolean(imageUrlFromBlock(block))));
}

function tokensEqual(left, right) {
  const a = Buffer.from(left || "");
  const b = Buffer.from(right || "");
  return a.length === b.length && a.length > 0 && crypto.timingSafeEqual(a, b);
}

function isAuthorized(req) {
  if (!BRIDGE_AUTH_TOKEN) return true;
  return tokensEqual(req.headers["x-bridge-token"], BRIDGE_AUTH_TOKEN);
}

async function replaceImages(content) {
  const output = [];
  for (const block of content || []) {
    const imageUrl = imageUrlFromBlock(block);
    if (!imageUrl) {
      output.push(block);
      continue;
    }
    try {
      const description = await describeImage(imageUrl, { prompt: VISION_PROMPT });
      log("VISION", `converted image payload (${imageUrl.length} chars)`);
      output.push({ type: "text", text: `[图片内容] ${description}` });
    } catch (error) {
      log("VISION-ERR", error.message);
      output.push({ type: "text", text: "[图片识别失败：请检查本地 Vision Bridge 日志]" });
    }
  }
  return output;
}

function upstreamUrlFor(urlPath) {
  const url = new URL(UPSTREAM);
  const incoming = new URL(urlPath || "/", "http://bridge.invalid");
  const basePath = url.pathname.replace(/\/+$/, "");
  let requestPath = incoming.pathname;
  if (basePath && basePath !== "/"
      && (requestPath === basePath || requestPath.startsWith(`${basePath}/`))) {
    requestPath = requestPath.slice(basePath.length) || "/";
  }
  url.pathname = `${basePath}/${requestPath.replace(/^\/+/, "")}`.replace(/\/+/g, "/");
  url.search = incoming.search;
  return url;
}

function proxyRequest(clientReq, clientRes, urlPath, body) {
  const upstreamUrl = upstreamUrlFor(urlPath);
  const transport = upstreamUrl.protocol === "https:" ? https : http;
  const headers = { ...clientReq.headers, host: upstreamUrl.host };
  delete headers["transfer-encoding"];
  delete headers["x-bridge-token"];
  if (body?.length) headers["content-length"] = body.length;
  else delete headers["content-length"];

  const req = transport.request(upstreamUrl, { method: clientReq.method, headers }, (res) => {
    clientRes.writeHead(res.statusCode || 502, res.headers);
    res.pipe(clientRes);
  });
  req.on("error", (error) => {
    log("UPSTREAM-ERR", urlPath, error.message);
    if (!clientRes.headersSent) {
      clientRes.writeHead(502, { "content-type": "text/plain; charset=utf-8" });
    }
    clientRes.end(`bridge upstream error: ${error.message}`);
  });
  req.setTimeout(UPSTREAM_TIMEOUT_MS, () => {
    req.destroy(new Error(`Upstream timed out after ${UPSTREAM_TIMEOUT_MS} ms`));
  });
  req.end(body?.length ? body : undefined);
}

if (!UPSTREAM) {
  console.error("UPSTREAM is required. Set it to the original DeepSeek provider base URL.");
  process.exit(1);
}

const server = http.createServer((clientReq, clientRes) => {
  const urlPath = clientReq.url || "/";
  log("REQ", clientReq.method, urlPath);
  if (clientReq.method === "GET" && ["/", "/health"].includes(pathOnly(urlPath))) {
    clientRes.writeHead(200, { "content-type": "application/json; charset=utf-8" });
    clientRes.end(JSON.stringify({
      ok: true,
      service: "vision-bridge",
      host: HOST,
      port: PORT,
      visionModel: VISION_MODEL,
      visionConfigured: Boolean(process.env.VISION_API_KEY),
      authRequired: Boolean(BRIDGE_AUTH_TOKEN),
    }));
    return;
  }
  if (!isAuthorized(clientReq)) {
    clientRes.writeHead(401, { "content-type": "application/json; charset=utf-8" });
    clientRes.end(JSON.stringify({ error: "invalid bridge token" }));
    return;
  }

  const chunks = [];
  let totalBytes = 0;
  let rejected = false;
  clientReq.on("data", (chunk) => {
    if (rejected) return;
    totalBytes += chunk.length;
    if (totalBytes > MAX_BODY_BYTES) {
      rejected = true;
      clientRes.writeHead(413, { "content-type": "text/plain; charset=utf-8" });
      clientRes.end("bridge request body is too large");
      clientReq.destroy();
      return;
    }
    chunks.push(chunk);
  });
  clientReq.on("end", async () => {
    if (rejected) return;
    const rawBody = Buffer.concat(chunks);
    if (!isSupportedPath(urlPath) || rawBody.length === 0) {
      proxyRequest(clientReq, clientRes, urlPath, rawBody);
      return;
    }
    let payload;
    try {
      payload = JSON.parse(rawBody.toString("utf8"));
    } catch {
      proxyRequest(clientReq, clientRes, urlPath, rawBody);
      return;
    }
    if (!hasImages(payload)) {
      proxyRequest(clientReq, clientRes, urlPath, rawBody);
      return;
    }
    for (const message of payload.messages) {
      if (Array.isArray(message?.content)) message.content = await replaceImages(message.content);
    }
    proxyRequest(clientReq, clientRes, urlPath, Buffer.from(JSON.stringify(payload), "utf8"));
  });
});

server.on("clientError", (error, socket) => {
  log("CLIENT-ERR", error.message);
  socket.end("HTTP/1.1 400 Bad Request\r\n\r\n");
});

server.listen(PORT, HOST, () => {
  log(`vision-bridge listening on http://${HOST}:${PORT} -> ${UPSTREAM}`);
});
