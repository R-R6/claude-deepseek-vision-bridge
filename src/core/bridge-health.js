#!/usr/bin/env node
/** Check that a local Vision Bridge endpoint is healthy and on the managed version. */
const http = require("node:http");
const https = require("node:https");

const EXPECTED_VERSION = process.env.BRIDGE_EXPECTED_VERSION || "0.2.1";
const DEFAULT_URL = `http://${process.env.BRIDGE_HOST || "127.0.0.1"}:${process.env.BRIDGE_PORT || "15720"}/health`;

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
}

function requestHealth(urlValue) {
  const url = new URL(urlValue);
  if (!(["http:", "https:"].includes(url.protocol))) {
    throw new Error("health URL must use http or https");
  }
  const transport = url.protocol === "https:" ? https : http;
  const headers = {};
  if (process.env.BRIDGE_AUTH_TOKEN) {
    headers["x-bridge-token"] = process.env.BRIDGE_AUTH_TOKEN;
  }

  return new Promise((resolve, reject) => {
    const request = transport.get(url, { headers }, (response) => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => { body += chunk; });
      response.on("error", reject);
      response.on("end", () => {
        if (response.statusCode !== 200) {
          reject(new Error(`health endpoint returned HTTP ${response.statusCode}`));
          return;
        }
        let payload;
        try {
          payload = JSON.parse(body);
        } catch {
          reject(new Error("health endpoint returned invalid JSON"));
          return;
        }
        if (payload?.ok !== true
            || payload?.service !== "vision-bridge"
            || payload?.version !== EXPECTED_VERSION) {
          reject(new Error("health endpoint is not the managed Vision Bridge version"));
          return;
        }
        resolve(payload);
      });
    });
    request.setTimeout(Number(process.env.BRIDGE_HEALTH_TIMEOUT_MS || 2000), () => {
      request.destroy(new Error("health request timed out"));
    });
    request.on("error", reject);
  });
}

requestHealth(process.argv[2] || DEFAULT_URL)
  .catch((error) => fail(error instanceof Error ? error.message : String(error)));
