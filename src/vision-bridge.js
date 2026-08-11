#!/usr/bin/env node
/** Convert image blocks to text before forwarding to a text-only model. */
const crypto = require("node:crypto");
const http = require("node:http");
const https = require("node:https");
const {
  describeImage,
  imageUrlFromBlock,
  isLoopbackHostname,
  positiveInteger,
  validateServiceUrl,
} = require("./vision-client");

function configurationError(message) {
  console.error(`Configuration error: ${message}`);
  process.exit(1);
}

const HOST = process.env.BRIDGE_HOST || "127.0.0.1";
let PORT;
let MAX_BODY_BYTES;
let MAX_IMAGES;
let MAX_CONCURRENT_VISION_REQUESTS;
let MAX_VISION_JOBS;
let UPSTREAM_TIMEOUT_MS;
let HEADERS_TIMEOUT_MS;
let BODY_TIMEOUT_MS;
let TOTAL_REQUEST_TIMEOUT_MS;
let KEEP_ALIVE_TIMEOUT_MS;
try {
  PORT = positiveInteger(process.env.BRIDGE_PORT, 15720, "BRIDGE_PORT", 1, 65535);
  MAX_BODY_BYTES = positiveInteger(
    process.env.BRIDGE_MAX_BODY_BYTES,
    25 * 1024 * 1024,
    "BRIDGE_MAX_BODY_BYTES",
    1024,
    100 * 1024 * 1024,
  );
  MAX_IMAGES = positiveInteger(process.env.BRIDGE_MAX_IMAGES, 8, "BRIDGE_MAX_IMAGES", 1, 100);
  MAX_CONCURRENT_VISION_REQUESTS = positiveInteger(
    process.env.BRIDGE_MAX_CONCURRENT_VISION_REQUESTS,
    2,
    "BRIDGE_MAX_CONCURRENT_VISION_REQUESTS",
    1,
    32,
  );
  MAX_VISION_JOBS = positiveInteger(
    process.env.BRIDGE_MAX_VISION_JOBS,
    16,
    "BRIDGE_MAX_VISION_JOBS",
    1,
    128,
  );
  UPSTREAM_TIMEOUT_MS = positiveInteger(
    process.env.UPSTREAM_TIMEOUT_MS,
    120000,
    "UPSTREAM_TIMEOUT_MS",
    1000,
    600000,
  );
  HEADERS_TIMEOUT_MS = positiveInteger(
    process.env.BRIDGE_HEADERS_TIMEOUT_MS,
    30000,
    "BRIDGE_HEADERS_TIMEOUT_MS",
    1000,
    120000,
  );
  BODY_TIMEOUT_MS = positiveInteger(
    process.env.BRIDGE_BODY_TIMEOUT_MS,
    120000,
    "BRIDGE_BODY_TIMEOUT_MS",
    1000,
    600000,
  );
  TOTAL_REQUEST_TIMEOUT_MS = positiveInteger(
    process.env.BRIDGE_TOTAL_REQUEST_TIMEOUT_MS,
    300000,
    "BRIDGE_TOTAL_REQUEST_TIMEOUT_MS",
    1000,
    1800000,
  );
  KEEP_ALIVE_TIMEOUT_MS = positiveInteger(
    process.env.BRIDGE_KEEP_ALIVE_TIMEOUT_MS,
    5000,
    "BRIDGE_KEEP_ALIVE_TIMEOUT_MS",
    1000,
    120000,
  );
} catch (error) {
  configurationError(error.message);
}

const UPSTREAM = process.env.UPSTREAM || "";
const BRIDGE_AUTH_TOKEN = process.env.BRIDGE_AUTH_TOKEN || "";
const VISION_PROMPT = process.env.VISION_PROMPT
  || "用简短中文准确描述图片内容；如有文字，优先完整抄录与问题最相关的文字。";
const VISION_BASE_URL = process.env.VISION_BASE_URL || "https://api.stepfun.com/v1";
let UPSTREAM_URL;
let VISION_URL;
try {
  UPSTREAM_URL = validateServiceUrl(UPSTREAM, "UPSTREAM");
  VISION_URL = validateServiceUrl(VISION_BASE_URL, "VISION_BASE_URL");
} catch (error) {
  configurationError(UPSTREAM ? error.message : "UPSTREAM is required");
}

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

function warnIfInsecure(url, name) {
  if (url.protocol === "http:" && !isLoopbackHostname(url.hostname)) {
    console.warn(`SECURITY WARNING: ${name} uses non-loopback HTTP; credentials and image data may be exposed.`);
  }
}

warnIfInsecure(UPSTREAM_URL, "UPSTREAM");
warnIfInsecure(VISION_URL, "VISION_BASE_URL");

function pathOnly(urlPath) {
  return (urlPath || "/").split("?", 1)[0];
}

function safeUrlForLog(value) {
  try {
    const url = new URL(value);
    url.username = "";
    url.password = "";
    url.search = "";
    url.hash = "";
    return url.toString();
  } catch {
    return "[invalid-url]";
  }
}

if (!isLoopbackHostname(HOST) && !BRIDGE_AUTH_TOKEN) {
  configurationError("BRIDGE_AUTH_TOKEN is required when BRIDGE_HOST is not loopback");
}

function isSupportedPath(urlPath) {
  return /^\/(?:v1\/)?(?:messages|chat\/completions)\/?$/.test(pathOnly(urlPath));
}

function imageCount(payload) {
  if (!Array.isArray(payload?.messages)) return 0;
  return payload.messages.reduce((count, message) => count + (
    Array.isArray(message?.content)
      ? message.content.filter((block) => Boolean(imageUrlFromBlock(block))).length
      : 0
  ), 0);
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

const HOP_BY_HOP_HEADERS = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

function stripHopByHopHeaders(headers) {
  const output = { ...headers };
  const connection = output.connection;
  HOP_BY_HOP_HEADERS.forEach((header) => delete output[header]);
  if (typeof connection === "string") {
    for (const header of connection.split(",")) {
      delete output[header.trim().toLowerCase()];
    }
  }
  return output;
}

const visionWaiters = [];
let activeVisionRequests = 0;
let activeVisionJobs = 0;

function reserveVisionJob() {
  if (activeVisionJobs >= MAX_VISION_JOBS) return null;
  activeVisionJobs += 1;
  let released = false;
  return () => {
    if (released) return;
    released = true;
    activeVisionJobs -= 1;
  };
}

function acquireVisionSlot(signal) {
  if (signal?.aborted) return Promise.reject(new Error("client disconnected"));
  if (activeVisionRequests < MAX_CONCURRENT_VISION_REQUESTS) {
    activeVisionRequests += 1;
    return Promise.resolve();
  }
  return new Promise((resolve, reject) => {
    const waiter = { resolve, reject, signal };
    const onAbort = () => {
      const index = visionWaiters.indexOf(waiter);
      if (index >= 0) visionWaiters.splice(index, 1);
      reject(new Error("client disconnected"));
    };
    waiter.onAbort = onAbort;
    signal?.addEventListener("abort", onAbort, { once: true });
    visionWaiters.push(waiter);
  });
}

function releaseVisionSlot() {
  const waiter = visionWaiters.shift();
  if (!waiter) {
    activeVisionRequests -= 1;
    return;
  }
  waiter.signal?.removeEventListener("abort", waiter.onAbort);
  if (waiter.signal?.aborted) {
    releaseVisionSlot();
    return;
  }
  waiter.resolve();
}

async function withVisionSlot(task, signal) {
  await acquireVisionSlot(signal);
  try {
    return await task();
  } finally {
    releaseVisionSlot();
  }
}

async function replaceImages(content, signal) {
  const output = [];
  for (const block of content || []) {
    if (signal?.aborted) throw new Error("client disconnected");
    const imageUrl = imageUrlFromBlock(block);
    if (!imageUrl) {
      output.push(block);
      continue;
    }
    try {
      const description = await withVisionSlot(
        () => describeImage(imageUrl, { prompt: VISION_PROMPT, signal }),
        signal,
      );
      log("VISION", "converted image payload");
      output.push({ type: "text", text: `[图片内容] ${description}` });
    } catch (error) {
      if (signal?.aborted) throw error;
      log("VISION-ERR", error.message);
      output.push({ type: "text", text: "[图片识别失败：请检查本地 Vision Bridge 日志]" });
    }
  }
  return output;
}

function upstreamUrlFor(urlPath) {
  const url = new URL(UPSTREAM_URL);
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

function proxyRequest(clientReq, clientRes, urlPath, body, signal) {
  let upstreamUrl;
  try {
    upstreamUrl = upstreamUrlFor(urlPath);
  } catch (error) {
    clientRes.writeHead(400, { "content-type": "text/plain; charset=utf-8" });
    clientRes.end(`invalid request path: ${error.message}`);
    return;
  }
  const transport = upstreamUrl.protocol === "https:" ? https : http;
  const headers = stripHopByHopHeaders(clientReq.headers);
  headers.host = upstreamUrl.host;
  delete headers["x-bridge-token"];
  if (body?.length) headers["content-length"] = body.length;
  else delete headers["content-length"];

  const req = transport.request(upstreamUrl, { method: clientReq.method, headers, signal }, (res) => {
    clientRes.writeHead(res.statusCode || 502, stripHopByHopHeaders(res.headers));
    res.pipe(clientRes);
  });
  req.on("error", (error) => {
    if (signal?.aborted) return;
    log("UPSTREAM-ERR", pathOnly(urlPath), error.code || error.message);
    if (!clientRes.headersSent) {
      clientRes.writeHead(502, { "content-type": "text/plain; charset=utf-8" });
    }
    clientRes.end("bridge upstream error");
  });
  req.setTimeout(UPSTREAM_TIMEOUT_MS, () => {
    req.destroy(new Error(`Upstream timed out after ${UPSTREAM_TIMEOUT_MS} ms`));
  });
  req.end(body?.length ? body : undefined);
}

function jsonResponse(res, status, body, extraHeaders = {}) {
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    ...extraHeaders,
  });
  res.end(JSON.stringify(body));
}

const server = http.createServer((clientReq, clientRes) => {
  const urlPath = clientReq.url || "/";
  const abortController = new AbortController();
  clientReq.on("aborted", () => abortController.abort());
  clientReq.on("error", () => abortController.abort());
  clientRes.on("close", () => {
    if (!clientRes.writableFinished) abortController.abort();
  });
  log("REQ", clientReq.method, pathOnly(urlPath));

  if (!isAuthorized(clientReq)) {
    jsonResponse(clientRes, 401, { error: "invalid bridge token" });
    return;
  }
  if (clientReq.method === "GET" && ["/", "/health"].includes(pathOnly(urlPath))) {
    jsonResponse(clientRes, 200, { ok: true, service: "vision-bridge" });
    return;
  }

  const chunks = [];
  let totalBytes = 0;
  let rejected = false;
  clientReq.on("data", (chunk) => {
    if (rejected || abortController.signal.aborted) return;
    totalBytes += chunk.length;
    if (totalBytes > MAX_BODY_BYTES) {
      rejected = true;
      abortController.abort();
      clientRes.writeHead(413, { "content-type": "text/plain; charset=utf-8" });
      clientRes.end("bridge request body is too large");
      clientReq.destroy();
      return;
    }
    chunks.push(chunk);
  });
  clientReq.on("end", async () => {
    if (rejected || abortController.signal.aborted) return;
    const rawBody = Buffer.concat(chunks);
    if (!isSupportedPath(urlPath) || rawBody.length === 0) {
      proxyRequest(clientReq, clientRes, urlPath, rawBody, abortController.signal);
      return;
    }
    let payload;
    try {
      payload = JSON.parse(rawBody.toString("utf8"));
    } catch {
      proxyRequest(clientReq, clientRes, urlPath, rawBody, abortController.signal);
      return;
    }
    const totalImages = imageCount(payload);
    if (totalImages > MAX_IMAGES) {
      jsonResponse(clientRes, 413, {
        error: `too many images; maximum is ${MAX_IMAGES}`,
      });
      return;
    }
    if (totalImages === 0) {
      proxyRequest(clientReq, clientRes, urlPath, rawBody, abortController.signal);
      return;
    }

    const releaseJob = reserveVisionJob();
    if (!releaseJob) {
      jsonResponse(
        clientRes,
        429,
        { error: "too many vision requests in progress; retry later" },
        { "retry-after": "1" },
      );
      return;
    }

    let timedOut = false;
    const deadline = setTimeout(() => {
      timedOut = true;
      abortController.abort();
    }, TOTAL_REQUEST_TIMEOUT_MS);
    try {
      for (const message of payload.messages) {
        if (Array.isArray(message?.content)) {
          message.content = await replaceImages(message.content, abortController.signal);
        }
      }
      if (!abortController.signal.aborted) {
        proxyRequest(
          clientReq,
          clientRes,
          urlPath,
          Buffer.from(JSON.stringify(payload), "utf8"),
          abortController.signal,
        );
      }
    } catch (error) {
      if (!abortController.signal.aborted) {
        log("VISION-ERR", error.code || error.message);
        jsonResponse(clientRes, 502, { error: "vision conversion failed" });
      } else if (timedOut && !clientRes.writableEnded) {
        jsonResponse(clientRes, 504, { error: "vision request timed out" });
      }
    } finally {
      clearTimeout(deadline);
      releaseJob();
    }
  });
});

server.headersTimeout = HEADERS_TIMEOUT_MS;
server.requestTimeout = BODY_TIMEOUT_MS;
server.keepAliveTimeout = KEEP_ALIVE_TIMEOUT_MS;

server.on("clientError", (error, socket) => {
  log("CLIENT-ERR", error.code || error.message);
  socket.end("HTTP/1.1 400 Bad Request\r\n\r\n");
});

server.on("error", (error) => {
  console.error(`Vision Bridge server error: ${error.code || error.message}`);
  process.exitCode = 1;
});

server.listen(PORT, HOST, () => {
  log(`vision-bridge listening on http://${HOST}:${PORT} -> ${safeUrlForLog(UPSTREAM)}`);
});