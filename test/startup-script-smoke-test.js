#!/usr/bin/env node
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");

if (process.platform !== "win32") {
  console.log("startup script smoke test: SKIP (Windows only)");
  process.exit(0);
}

const sourceRoot = path.join(__dirname, "..", "src");
const coreDir = path.join(sourceRoot, "core");
const windowsDir = path.join(sourceRoot, "windows");
const powershell = "powershell.exe";

function trace(message) {
  if (process.env.STARTUP_SMOKE_TRACE === "1") {
    console.error(`[startup smoke] ${message}`);
  }
}

function traceDuration(label, startedAt) {
  trace(`${label} completed in ${Date.now() - startedAt} ms`);
}

function assertSpawnCompleted(result, label) {
  if (result.error) {
    throw new Error(`${label} did not complete: ${result.error.message}`);
  }
}

function listen(server) {
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server.address().port)));
}

function listenAt(server, port) {
  return new Promise((resolve, reject) => {
    const onError = (error) => {
      server.removeListener("listening", onListening);
      reject(error);
    };
    const onListening = () => {
      server.removeListener("error", onError);
      resolve(server.address().port);
    };
    server.once("error", onError);
    server.once("listening", onListening);
    server.listen(port, "127.0.0.1");
  });
}

function close(server, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const timer = setTimeout(() => {
      if (typeof server.closeAllConnections === "function") {
        trace("forcing mock server connections closed");
        server.closeAllConnections();
        return;
      }
      finish(reject, new Error("mock server did not close within " + timeoutMs + " ms"));
    }, timeoutMs);
    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      callback(value);
    };
    server.close((error) => {
      if (error && error.code !== "ERR_SERVER_NOT_RUNNING") {
        finish(reject, error);
        return;
      }
      finish(resolve);
    });
  });
}

function getJson(port, urlPath, headers = {}) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      callback(value);
    };
    const request = http.get({ host: "127.0.0.1", port, path: urlPath, headers, agent: false }, (res) => {
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => { body += chunk; });
      res.on("aborted", () => finish(reject, new Error("health response aborted")));
      res.on("error", (error) => finish(reject, error));
      res.on("close", () => finish(reject, new Error("health response closed before completion")));
      res.on("end", () => {
        try {
          finish(resolve, { status: res.statusCode, body: JSON.parse(body) });
        } catch (error) {
          finish(reject, error);
        }
      });
    });
    request.setTimeout(1000, () => {
      trace("request timeout");
      request.destroy(new Error("health request timed out"));
    });
    request.on("error", (error) => { trace(`request error ${error.code || error.message}`); finish(reject, error); });
  });
}

function postJson(port, urlPath, payload, headers = {}) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      callback(value);
    };
    const body = JSON.stringify(payload);
    const requestHeaders = {
      "content-type": "application/json",
      "content-length": Buffer.byteLength(body),
      ...headers,
    };
    const request = http.request({
      host: "127.0.0.1",
      port,
      path: urlPath,
      method: "POST",
      headers: requestHeaders,
      agent: false,
    }, (response) => {
      let responseBody = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => { responseBody += chunk; });
      response.on("error", (error) => {
        finish(reject, new Error(`POST ${urlPath} response failed: ${error.message}`, { cause: error }));
      });
      response.on("aborted", () => {
        finish(reject, new Error(`POST ${urlPath} response aborted`));
      });
      response.on("close", () => {
        if (!response.complete) {
          finish(reject, new Error(`POST ${urlPath} response closed before completion`));
        }
      });
      response.on("end", () => {
        let parsed;
        try {
          parsed = JSON.parse(responseBody);
        } catch {
          parsed = responseBody;
        }
        finish(resolve, { status: response.statusCode, body: parsed });
      });
    });
    request.on("error", (error) => {
      finish(reject, new Error(`POST ${urlPath} request failed: ${error.message}`, { cause: error }));
    });
    const timer = setTimeout(() => {
      const error = new Error(`POST ${urlPath} timed out`);
      request.destroy(error);
      finish(reject, error);
    }, 5000);
    request.end(body);
  });
}

function freePort() {
  const probe = http.createServer();
  return listen(probe).then((port) => close(probe).then(() => port));
}

function createBundle(homeDir) {
  const bridgeDir = path.join(homeDir, ".claude", "bridge");
  fs.mkdirSync(bridgeDir, { recursive: true });
  const sources = {
    "vision-bridge.js": path.join(coreDir, "vision-bridge.js"),
    "vision-client.js": path.join(coreDir, "vision-client.js"),
    "start-vision-bridge.ps1": path.join(windowsDir, "start-vision-bridge.ps1"),
    "restart-vision-bridge.ps1": path.join(windowsDir, "restart-vision-bridge.ps1"),
    "start-ccswitch-after-bridge.vbs": path.join(windowsDir, "start-ccswitch-after-bridge.vbs"),
  };
  for (const [name, source] of Object.entries(sources)) {
    fs.copyFileSync(source, path.join(bridgeDir, name));
  }
  return bridgeDir;
}

function runLauncher(homeDir, port, extraEnv = {}) {
  const launcher = path.join(homeDir, ".claude", "bridge", "start-vision-bridge.ps1");
  const startedAt = Date.now();
  const child = spawn(powershell, [
    "-NoLogo",
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    launcher,
  ], {
    env: {
      ...process.env,
      USERPROFILE: homeDir,
      BRIDGE_HOST: "127.0.0.1",
      BRIDGE_PORT: String(port),
      BRIDGE_AUTH_TOKEN: "startup-test-token",
      UPSTREAM: "http://127.0.0.1:1/v1",
      VISION_BASE_URL: "http://127.0.0.1:1/v1",
      VISION_MODEL: "startup-test-vision-model",
      VISION_API_KEY: "startup-test-key",
      BRIDGE_STARTUP_TIMEOUT_MS: "30000",
      ...extraEnv,
    },
    windowsHide: true,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");

  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (result, terminateLauncher = false) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (terminateLauncher && child.exitCode === null) child.kill();
      traceDuration("launcher", startedAt);
      resolve(result);
    };
    const timer = setTimeout(() => {
      if (child.exitCode === null) child.kill();
      reject(new Error(`launcher did not report a terminal result within 15000 ms: ${stdout}\n${stderr}`));
    }, 15000);
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
      if (/Vision Bridge (?:started and passed health check|is already healthy)/.test(stdout)) {
        // The bridge is an independent child process. The test only needs the launcher result.
        finish({ status: 0, stdout, stderr }, true);
      }
    });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (status, signal) => finish({ status, signal, stdout, stderr }));
  });
}

function runRestart(homeDir, port, upstream, extraEnv = {}, extraArgs = []) {
  const startedAt = Date.now();
  const result = spawnSync(powershell, [
    "-NoLogo",
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    path.join(homeDir, ".claude", "bridge", "restart-vision-bridge.ps1"),
    "-EnvironmentScope",
    "Process",
    ...extraArgs,
  ], {
    env: {
      ...process.env,
      USERPROFILE: homeDir,
      BRIDGE_HOST: "127.0.0.1",
      BRIDGE_PORT: String(port),
      BRIDGE_AUTH_TOKEN: "startup-test-token",
      UPSTREAM: upstream,
      VISION_BASE_URL: "http://127.0.0.1:1/v1",
      VISION_MODEL: "startup-test-vision-model",
      VISION_API_KEY: "startup-test-key",
      BRIDGE_STARTUP_TIMEOUT_MS: "30000",
      ...extraEnv,
    },
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 60000,
  });
  assertSpawnCompleted(result, "restart");
  traceDuration("restart", startedAt);
  return result;
}

function runDiagnostic(homeDir, port, options = {}) {
  const routePort = options.routePort ?? port;
  const settingsPath = path.join(homeDir, ".claude", "settings.json");
  fs.mkdirSync(path.dirname(settingsPath), { recursive: true });
  fs.writeFileSync(settingsPath, JSON.stringify({
    env: { ANTHROPIC_BASE_URL: "http://127.0.0.1:" + routePort },
  }), "utf8");
  const diagnosticArgs = ["-SkipCCSwitch"];
  if (Number.isInteger(options.expectedRoutePort)) {
    diagnosticArgs.push("-ExpectedRoutePort", String(options.expectedRoutePort));
  }
  if (options.skipRouteCheck) diagnosticArgs.push("-SkipRouteCheck");
  const startedAt = Date.now();
  const result = spawnSync(powershell, [
    "-NoLogo",
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    path.join(windowsDir, "diagnose-vision-bridge.ps1"),
    ...diagnosticArgs,
  ], {
    env: {
      ...process.env,
      USERPROFILE: homeDir,
      BRIDGE_HOST: "127.0.0.1",
      BRIDGE_PORT: String(port),
      BRIDGE_AUTH_TOKEN: "startup-test-token",
      UPSTREAM: "https://new.example/v1",
      VISION_BASE_URL: "https://vision.example/v1",
      VISION_MODEL: "startup-test-vision-model",
      VISION_API_KEY: "startup-test-key",
    },
    encoding: "utf8",
    timeout: 10000,
  });
  traceDuration("diagnostic", startedAt);
  return result;
}

function runDiagnosticWithOutput(homeDir, port, options = {}) {
  const result = runDiagnostic(homeDir, port, options);
  if (options.expectPass) {
    assert.equal(result.status, 0, result.stdout + "\n" + result.stderr);
  } else {
    assert.notEqual(result.status, 0, result.stdout + "\n" + result.stderr);
  }
  return result;
}

function createVisionMock(description) {
  const mock = { requests: 0, server: null };
  mock.server = http.createServer((req, res) => {
    mock.requests += 1;
    req.resume();
    req.on("end", () => {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ choices: [{ message: { content: description } }] }));
    });
  });
  return mock;
}

function runInstaller(homeDir, startupDir, extraArgs = []) {
  const startedAt = Date.now();
  const result = spawnSync(powershell, [
    "-NoLogo",
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    path.join(windowsDir, "install-vision-bridge.ps1"),
    "-InstallUserProfile",
    homeDir,
    "-StartupDirectory",
    startupDir,
    ...extraArgs,
  ], { encoding: "utf8", timeout: 15000 });
  traceDuration("installer", startedAt);
  return result;
}

function setRegistryValue(keyPath, valueName, value) {
  const command = [
    "New-Item -Path $env:TEST_REGISTRY_KEY -Force | Out-Null;",
    "New-ItemProperty -Path $env:TEST_REGISTRY_KEY -Name $env:TEST_REGISTRY_NAME -Value $env:TEST_REGISTRY_VALUE -PropertyType String -Force | Out-Null;",
  ].join(" ");
  const result = spawnSync(powershell, ["-NoLogo", "-NoProfile", "-Command", command], {
    env: {
      ...process.env,
      TEST_REGISTRY_KEY: keyPath,
      TEST_REGISTRY_NAME: valueName,
      TEST_REGISTRY_VALUE: value,
    },
    encoding: "utf8",
    timeout: 5000,
  });
  assert.equal(result.status, 0, "cannot prepare test registry value");
}

function getRegistryValue(keyPath, valueName) {
  const command = "([string](Get-ItemProperty -LiteralPath $env:TEST_REGISTRY_KEY).$env:TEST_REGISTRY_NAME)";
  const result = spawnSync(powershell, ["-NoLogo", "-NoProfile", "-Command", command], {
    env: {
      ...process.env,
      TEST_REGISTRY_KEY: keyPath,
      TEST_REGISTRY_NAME: valueName,
    },
    encoding: "utf8",
    timeout: 5000,
  });
  assert.equal(result.status, 0, "cannot read test registry value");
  return result.stdout.trim();
}

function getRegistryValueOrEmpty(keyPath, valueName) {
  const command = "if (Test-Path -LiteralPath $env:TEST_REGISTRY_KEY) { ([string](Get-ItemProperty -LiteralPath $env:TEST_REGISTRY_KEY).$env:TEST_REGISTRY_NAME) }";
  const result = spawnSync(powershell, ["-NoLogo", "-NoProfile", "-Command", command], {
    env: {
      ...process.env,
      TEST_REGISTRY_KEY: keyPath,
      TEST_REGISTRY_NAME: valueName,
    },
    encoding: "utf8",
    timeout: 5000,
  });
  assert.equal(result.status, 0, "cannot read optional test registry value");
  return result.stdout.trim();
}

function removeRegistryKey(keyPath) {
  const command = "Remove-Item -LiteralPath $env:TEST_REGISTRY_KEY -Recurse -Force -ErrorAction SilentlyContinue";
  const result = spawnSync(powershell, ["-NoLogo", "-NoProfile", "-Command", command], {
    env: { ...process.env, TEST_REGISTRY_KEY: keyPath },
    encoding: "utf8",
    timeout: 5000,
  });
  assert.equal(result.status, 0, "cannot remove test registry key");
}

function runRestore(homeDir, keyPath) {
  const startedAt = Date.now();
  const result = spawnSync(powershell, [
    "-NoLogo",
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    path.join(windowsDir, "restore-ccswitch-startup.ps1"),
    "-InstallUserProfile",
    homeDir,
    "-CCSwitchRunKeyPath",
    keyPath,
  ], { encoding: "utf8", timeout: 15000 });
  traceDuration("startup restore", startedAt);
  return result;
}

function runStartupVbs(homeDir, startupDir, port) {
  const cscript = path.join(process.env.SystemRoot || "C:\\Windows", "System32", "cscript.exe");
  const startedAt = Date.now();
  const result = spawnSync(cscript, ["//nologo", path.join(startupDir, "vision-bridge.vbs")], {
    env: {
      ...process.env,
      USERPROFILE: homeDir,
      BRIDGE_HOST: "127.0.0.1",
      BRIDGE_PORT: String(port),
      BRIDGE_AUTH_TOKEN: "startup-test-token",
      UPSTREAM: "http://127.0.0.1:1/v1",
      VISION_BASE_URL: "http://127.0.0.1:1/v1",
      VISION_API_KEY: "startup-test-key",
      BRIDGE_STARTUP_TIMEOUT_MS: "5000",
    },
    encoding: "utf8",
    timeout: 5000,
  });
  traceDuration("startup vbs", startedAt);
  return result;
}

function runCCSwitchCoordinator(homeDir, port, timeoutMs = 5000) {
  const cscript = path.join(process.env.SystemRoot || "C:\\Windows", "System32", "cscript.exe");
  return spawn(cscript, [
    "//nologo",
    path.join(homeDir, ".claude", "bridge", "start-ccswitch-after-bridge.vbs"),
  ], {
    env: {
      ...process.env,
      USERPROFILE: homeDir,
      BRIDGE_HOST: "127.0.0.1",
      BRIDGE_PORT: String(port),
      BRIDGE_STARTUP_COORDINATOR_TIMEOUT_MS: String(timeoutMs),
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
}

function waitForChildExit(child, timeoutMs = 10000) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const timer = setTimeout(() => {
      if (typeof child.kill === "function") child.kill();
      finish(reject, new Error("child process did not exit within " + timeoutMs + " ms"));
    }, timeoutMs);
    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.removeListener("error", onError);
      child.removeListener("exit", onExit);
      callback(value);
    };
    const onError = (error) => finish(reject, error);
    const onExit = (code, signal) => finish(resolve, { code, signal });
    if (child.exitCode !== null) {
      finish(resolve, { code: child.exitCode, signal: child.signalCode });
      return;
    }
    child.once("error", onError);
    child.once("exit", onExit);
  });
}

async function waitForFile(filePath, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (fs.existsSync(filePath)) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("file was not created within " + timeoutMs + " ms: " + filePath);
}

async function removeFileWithRetry(filePath, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    try {
      fs.rmSync(filePath, { force: true });
      if (!fs.existsSync(filePath)) return;
    } catch (error) {
      lastError = error;
      if (!['EPERM', 'EBUSY', 'ENOTEMPTY'].includes(error.code)) throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  if (lastError) throw lastError;
  throw new Error("file could not be removed within " + timeoutMs + " ms: " + filePath);
}

function ownedProcessIds(homeDir) {
  const bridgeScript = path.join(homeDir, ".claude", "bridge", "vision-bridge.js");
  const command = [
    "$target = [Environment]::GetEnvironmentVariable('TEST_BRIDGE_SCRIPT', 'Process');",
    "Get-CimInstance Win32_Process |",
    "Where-Object { $_.Name -in @('node.exe', 'node') -and $_.CommandLine -like ('*' + $target + '*') } |",
    "ForEach-Object { $_.ProcessId }",
  ].join(" ");
  const result = spawnSync(powershell, ["-NoLogo", "-NoProfile", "-Command", command], {
    env: { ...process.env, TEST_BRIDGE_SCRIPT: bridgeScript },
    encoding: "utf8",
    timeout: 5000,
  });
  assert.equal(result.status, 0, `cannot inspect test bridge process:\n${result.stdout}\n${result.stderr}`);
  return result.stdout
    .split(/\r?\n/)
    .map((value) => value.trim())
    .filter((value) => /^\d+$/.test(value))
    .map(Number)
    .filter((value) => Number.isSafeInteger(value) && value > 0);
}

async function stopOwnedProcesses(homeDir) {
  const processIds = ownedProcessIds(homeDir);
  for (const processId of processIds) {
    const result = spawnSync("taskkill.exe", ["/PID", String(processId), "/T", "/F"], {
      encoding: "utf8",
      timeout: 5000,
    });
    assert.equal(result.status, 0, `cannot stop test bridge process ${processId}:\n${result.stdout}\n${result.stderr}`);
  }
  for (let attempt = 0; attempt < 50; attempt += 1) {
    if (ownedProcessIds(homeDir).length === 0) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`test bridge process did not exit: ${ownedProcessIds(homeDir).join(", ")}`);
}

function isPortListening(port) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      resolve(value);
    };
    const request = http.get({ host: "127.0.0.1", port, path: "/health", agent: false }, (res) => {
      res.resume();
      finish(true);
    });
    request.setTimeout(500, () => {
      request.destroy();
      finish(false);
    });
    request.on("error", () => finish(false));
  });
}

async function waitForPortClosed(port, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!(await isPortListening(port))) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("port did not close within " + timeoutMs + " ms: " + port);
}

async function waitForHealthy(port, token, timeoutMs = 5000, errorLogPath = "") {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const result = await getJson(port, "/health", { "x-bridge-token": token });
      if (result.status === 200 && result.body?.ok === true && result.body?.version === "0.2.1") {
        return result;
      }
    } catch (error) {
      trace(`health ${port} retry: ${error.code || error.message}`);
      // The startup entry is asynchronous; retry until the bounded deadline.
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  let detail = "";
  if (errorLogPath && fs.existsSync(errorLogPath)) {
    detail = `\n${fs.readFileSync(errorLogPath, "utf8")}`;
  }
  throw new Error(`bridge did not become healthy on port ${port}${detail}`);
}

async function postJsonWithRetry(port, urlPath, payload, headers = {}, attempts = 8) {
  let lastError;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      return await postJson(port, urlPath, payload, headers);
    } catch (error) {
      lastError = error;
      trace(`POST ${urlPath} retry ${attempt}: ${error.code || error.message}`);
      await new Promise((resolve) => setTimeout(resolve, 150));
    }
  }
  throw lastError;
}

async function removeTree(directory) {
  await stopOwnedProcesses(directory.root);
  fs.rmSync(directory.root, { recursive: true, force: true });
  assert.equal(fs.existsSync(directory.root), false, `test directory was not removed: ${directory.root}`);
}

async function main() {
  const installRoot = fs.mkdtempSync(path.join(os.tmpdir(), "vision bridge install-"));
  const installStartup = path.join(installRoot, "Startup Area");
  fs.mkdirSync(path.join(installRoot, ".claude", "bridge"), { recursive: true });
  fs.mkdirSync(installStartup, { recursive: true });
  fs.writeFileSync(path.join(installRoot, ".claude", "bridge", "vision-bridge.js"), "old bridge");
  fs.writeFileSync(path.join(installStartup, "vision-bridge.vbs"), "old startup");
  const normal = {
    root: fs.mkdtempSync(path.join(os.tmpdir(), "vision bridge startup-")),
    port: await freePort(),
  };
  const occupied = {
    root: fs.mkdtempSync(path.join(os.tmpdir(), "vision bridge occupied-")),
    port: 0,
  };
  const delayed = {
    root: fs.mkdtempSync(path.join(os.tmpdir(), "vision bridge delayed-")),
    port: await freePort(),
  };
  const restartCase = {
    root: fs.mkdtempSync(path.join(os.tmpdir(), "vision bridge restart-")),
    port: await freePort(),
  };
  const diagnosticCase = {
    root: fs.mkdtempSync(path.join(os.tmpdir(), "vision bridge diagnostic-")),
    port: await freePort(),
  };
  const upstreamOld = {
    requests: 0,
    payloads: [],
    server: http.createServer((req, res) => {
      upstreamOld.requests += 1;
      let body = "";
      req.setEncoding("utf8");
      req.on("data", (chunk) => { body += chunk; });
      req.on("end", () => {
        upstreamOld.payloads.push(JSON.parse(body));
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ source: "old" }));
      });
    }),
  };
  const upstreamNew = {
    requests: 0,
    payloads: [],
    server: http.createServer((req, res) => {
      upstreamNew.requests += 1;
      let body = "";
      req.setEncoding("utf8");
      req.on("data", (chunk) => { body += chunk; });
      req.on("end", () => {
        upstreamNew.payloads.push(JSON.parse(body));
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ source: "new" }));
      });
    }),
  };
  const visionOld = createVisionMock("restart-old-vision-description");
  const visionNew = createVisionMock("restart-new-vision-description");
  const upstreamOldPort = await listen(upstreamOld.server);
  const upstreamNewPort = await listen(upstreamNew.server);
  const visionOldPort = await listen(visionOld.server);
  const visionNewPort = await listen(visionNew.server);
  const vbsCase = {
    root: fs.mkdtempSync(path.join(os.tmpdir(), "vision bridge vbs-")),
    port: await freePort(),
  };
  const vbsStartup = path.join(vbsCase.root, "Startup Area");
  const coordinatorCase = {
    root: fs.mkdtempSync(path.join(os.tmpdir(), "vision bridge coordinator-")),
    port: await freePort(),
    marker: "",
    healthReady: false,
  };
  const coordinatorHealth = http.createServer((req, res) => {
    if (req.url === "/health" && coordinatorCase.healthReady) {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true, service: "vision-bridge", version: "0.2.1" }));
      return;
    }
    res.writeHead(503);
    res.end("not ready");
  });
  coordinatorCase.port = await listen(coordinatorHealth);
  const registryTestPath = "HKCU:\\Software\\claude-deepseek-vision-bridge-test-" + process.pid;
  let vbsRegistryPath;
  let occupiedServer;
  let coordinatorProcess;
  let unknownServer;
  const noCCSwitchRegistryPath = registryTestPath + "-none";
  try {
    const originalCCSwitchCommand = "C:\\Test Tools\\cc-switch.exe --startup";
    setRegistryValue(registryTestPath, "CC Switch", originalCCSwitchCommand);
    const installResult = runInstaller(installRoot, installStartup, [
      "-CCSwitchRunKeyPath",
      registryTestPath,
    ]);
    assert.equal(installResult.status, 0, `${installResult.stdout}\n${installResult.stderr}`);
    for (const relativePath of [
      ".claude/bridge/vision-bridge.js",
      ".claude/bridge/vision-client.js",
      ".claude/bridge/start-vision-bridge.ps1",
      ".claude/bridge/restart-vision-bridge.ps1",
      ".claude/bridge/start-ccswitch-after-bridge.vbs",
      ".claude/bridge/restore-ccswitch-startup.ps1",
      ".claude/bridge/diagnose-vision-bridge.ps1",
      ".claude/bridge/configure-ccswitch-route.ps1",
      ".claude/bridge/cc-switch-sqlite.js",
      ".claude/skills/vision/vision.js",
      ".claude/skills/vision/vision-client.js",
      ".claude/skills/vision/SKILL.md",
      "Startup Area/vision-bridge.vbs",
    ]) {
      assert.equal(fs.existsSync(path.join(installRoot, relativePath)), true, relativePath);
    }
    assert.match(getRegistryValue(registryTestPath, "CC Switch"), /start-ccswitch-after-bridge\.vbs/);
    const restoreResult = runRestore(installRoot, registryTestPath);
    assert.equal(
      restoreResult.status,
      0,
      restoreResult.stdout + "\n" + restoreResult.stderr,
    );
    assert.equal(getRegistryValue(registryTestPath, "CC Switch"), originalCCSwitchCommand);
    const backupDirs = fs.readdirSync(path.join(installRoot, ".claude", "bridge", "backups"));
    assert.equal(backupDirs.length, 1);
    assert.equal(fs.existsSync(path.join(
      installRoot,
      ".claude",
      "bridge",
      "backups",
      backupDirs[0],
      "bridge",
      "vision-bridge.js",
    )), true);

    setRegistryValue(registryTestPath, "CC Switch", originalCCSwitchCommand);
    const skippedCoordinationResult = runInstaller(installRoot, installStartup, [
      "-CCSwitchRunKeyPath",
      registryTestPath,
      "-SkipCCSwitchStartupCoordination",
    ]);
    assert.equal(
      skippedCoordinationResult.status,
      0,
      skippedCoordinationResult.stdout + "\n" + skippedCoordinationResult.stderr,
    );
    assert.match(skippedCoordinationResult.stdout, /coordination was skipped/i);
    assert.equal(getRegistryValue(registryTestPath, "CC Switch"), originalCCSwitchCommand);

    const noCCSwitchRoot = fs.mkdtempSync(path.join(os.tmpdir(), "vision bridge no-ccswitch-"));
    const noCCSwitchStartup = path.join(noCCSwitchRoot, "Startup Area");
    const noCCSwitchInstallResult = runInstaller(noCCSwitchRoot, noCCSwitchStartup, [
      "-CCSwitchRunKeyPath",
      noCCSwitchRegistryPath,
    ]);
    assert.equal(
      noCCSwitchInstallResult.status,
      0,
      noCCSwitchInstallResult.stdout + "\n" + noCCSwitchInstallResult.stderr,
    );
    assert.match(noCCSwitchInstallResult.stdout, /No recognizable CC Switch startup entry was found/i);
    assert.equal(getRegistryValueOrEmpty(noCCSwitchRegistryPath, "CC Switch"), "");
    assert.equal(
      fs.existsSync(path.join(noCCSwitchStartup, "vision-bridge.vbs")),
      true,
      "bridge startup must still install without CC Switch",
    );
    fs.rmSync(noCCSwitchRoot, { recursive: true, force: true });

    createBundle(normal.root);
    const missingVisionBaseUrl = await runLauncher(normal.root, normal.port, { VISION_BASE_URL: "" });
    assert.notEqual(missingVisionBaseUrl.status, 0);
    assert.match(`${missingVisionBaseUrl.stdout}\n${missingVisionBaseUrl.stderr}`, /VISION_BASE_URL is not configured/);
    const missingVisionModel = await runLauncher(normal.root, normal.port, { VISION_MODEL: "" });
    assert.notEqual(missingVisionModel.status, 0);
    assert.match(`${missingVisionModel.stdout}\n${missingVisionModel.stderr}`, /VISION_MODEL is not configured/);
    const normalResult = await runLauncher(normal.root, normal.port);
    assert.equal(normalResult.status, 0, `${normalResult.stdout}\n${normalResult.stderr}`);
    assert.match(normalResult.stdout, /passed health check/);
    const normalHealth = await getJson(normal.port, "/health", { "x-bridge-token": "startup-test-token" });
    assert.equal(normalHealth.status, 200);
    assert.equal(normalHealth.body.version, "0.2.1");
    await stopOwnedProcesses(normal.root);

    createBundle(restartCase.root);
    const oldStart = await runLauncher(restartCase.root, restartCase.port, {
      UPSTREAM: "http://127.0.0.1:" + upstreamOldPort + "/v1",
      VISION_BASE_URL: "http://127.0.0.1:" + visionOldPort + "/v1",
    });
    assert.equal(oldStart.status, 0, oldStart.stdout + "\n" + oldStart.stderr);
    fs.writeFileSync(
      path.join(restartCase.root, ".claude", "bridge", "bridge-rollback-state.dat"),
      "invalid migration state",
    );
    const bootstrapRestart = runRestart(
      restartCase.root,
      restartCase.port,
      "http://127.0.0.1:" + upstreamOldPort + "/v1",
      { VISION_BASE_URL: "http://127.0.0.1:" + visionOldPort + "/v1" },
      ["-BootstrapRollbackState"],
    );
    assert.equal(bootstrapRestart.status, 0, bootstrapRestart.stdout + "\n" + bootstrapRestart.stderr);
    const oldRequest = await postJson(
      restartCase.port,
      "/v1/chat/completions",
      { model: "text-model", messages: [{ role: "user", content: "old" }] },
      { "x-bridge-token": "startup-test-token" },
    );
    assert.equal(oldRequest.status, 200);
    assert.equal(upstreamOld.requests, 1);
    const oldImageRequest = await postJsonWithRetry(
      restartCase.port,
      "/v1/chat/completions",
      {
        model: "text-model",
        messages: [{ role: "user", content: [
          { type: "image_url", image_url: { url: "data:image/png;base64,AAAA" } },
        ] }],
      },
      { "x-bridge-token": "startup-test-token" },
    );
    assert.equal(oldImageRequest.status, 200);
    assert.equal(visionOld.requests, 1);
    assert.equal(upstreamOld.requests, 2);
    assert.match(JSON.stringify(upstreamOld.payloads.at(-1)), /restart-old-vision-description/);
    const restartResult = runRestart(
      restartCase.root,
      restartCase.port,
      "http://127.0.0.1:" + upstreamNewPort + "/v1",
      { VISION_BASE_URL: "http://127.0.0.1:" + visionNewPort + "/v1" },
    );
    trace(`successful restart result status=${restartResult.status}`);
    assert.equal(
      restartResult.status,
      0,
      restartResult.stdout + "\n" + restartResult.stderr +
        "\nerror=" + (restartResult.error?.message || "none") +
        "\nsignal=" + (restartResult.signal || "none") +
        "\nlog=" + (
          fs.existsSync(path.join(restartCase.root, ".claude", "bridge", "restart-vision-bridge.log"))
            ? fs.readFileSync(path.join(restartCase.root, ".claude", "bridge", "restart-vision-bridge.log"), "utf8")
            : "[missing]"
        ) +
        "\nerrorLog=" + (
          fs.existsSync(path.join(restartCase.root, ".claude", "bridge", "vision-bridge.err.log"))
            ? fs.readFileSync(path.join(restartCase.root, ".claude", "bridge", "vision-bridge.err.log"), "utf8")
            : "[missing]"
        ),
    );
    await waitForHealthy(restartCase.port, "startup-test-token", 5000);
    const newRequest = await postJsonWithRetry(
      restartCase.port,
      "/v1/chat/completions",
      { model: "text-model", messages: [{ role: "user", content: "new" }] },
      { "x-bridge-token": "startup-test-token" },
    );
    assert.equal(newRequest.status, 200);
    assert.equal(newRequest.body.source, "new");
    assert.equal(upstreamNew.requests, 1);
    const newImageRequest = await postJsonWithRetry(
      restartCase.port,
      "/v1/chat/completions",
      {
        model: "text-model",
        messages: [{ role: "user", content: [
          { type: "image_url", image_url: { url: "data:image/png;base64,AAAA" } },
        ] }],
      },
      { "x-bridge-token": "startup-test-token" },
    );
    assert.equal(newImageRequest.status, 200);
    assert.equal(visionNew.requests, 1);
    assert.equal(visionOld.requests, 1);
    assert.equal(upstreamNew.requests, 2);
    assert.equal(upstreamOld.requests, 2);
    assert.match(JSON.stringify(upstreamNew.payloads.at(-1)), /restart-new-vision-description/);
    trace("successful restart request passed");
    const failedRestart = runRestart(
      restartCase.root,
      restartCase.port,
      "http://127.0.0.1:" + upstreamNewPort + "/v1",
      { VISION_BASE_URL: "http://[invalid" },
    );
    trace(`failed restart result status=${failedRestart.status}`);
    assert.notEqual(failedRestart.status, 0, failedRestart.stdout + "\n" + failedRestart.stderr);
    assert.match(
      failedRestart.stdout + "\n" + failedRestart.stderr,
      /previous Vision Bridge configuration was restored successfully/i,
    );
    const restoredRequest = await postJsonWithRetry(
      restartCase.port,
      "/v1/chat/completions",
      { model: "text-model", messages: [{ role: "user", content: "restored" }] },
      { "x-bridge-token": "startup-test-token" },
    );
    assert.equal(restoredRequest.status, 200);
    assert.equal(restoredRequest.body.source, "new");
    assert.equal(visionNew.requests, 1);
    assert.equal(visionOld.requests, 1);
    const restoredImageRequest = await postJsonWithRetry(
      restartCase.port,
      "/v1/chat/completions",
      {
        model: "text-model",
        messages: [{ role: "user", content: [
          { type: "image_url", image_url: { url: "data:image/png;base64,AAAA" } },
        ] }],
      },
      { "x-bridge-token": "startup-test-token" },
    );
    assert.equal(restoredImageRequest.status, 200);
    assert.equal(visionNew.requests, 2);
    assert.equal(visionOld.requests, 1);
    assert.match(JSON.stringify(upstreamNew.payloads.at(-1)), /restart-new-vision-description/);
    trace("rollback request passed");
    createBundle(diagnosticCase.root);
    const diagnosticStart = await runLauncher(diagnosticCase.root, diagnosticCase.port);
    assert.equal(diagnosticStart.status, 0, diagnosticStart.stdout + "\n" + diagnosticStart.stderr);
    const diagnosticPass = runDiagnosticWithOutput(diagnosticCase.root, diagnosticCase.port, { expectPass: true });
    assert.match(diagnosticPass.stdout, /Required process configuration/);
    assert.match(diagnosticPass.stdout, /Restart rollback state/);
    const routerPort = await freePort();
    const routerDiagnosticPass = runDiagnosticWithOutput(
      diagnosticCase.root,
      diagnosticCase.port,
      { expectPass: true, routePort: routerPort, expectedRoutePort: routerPort },
    );
    assert.match(routerDiagnosticPass.stdout, /expected 127\.0\.0\.1:/);
    const skippedRouteDiagnosticPass = runDiagnosticWithOutput(
      diagnosticCase.root,
      diagnosticCase.port,
      { expectPass: true, routePort: routerPort, skipRouteCheck: true },
    );
    assert.match(skippedRouteDiagnosticPass.stdout, /route check skipped/);

    const occupiedBundle = createBundle(occupied.root);
    occupiedServer = http.createServer((req, res) => {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true, service: "vision-bridge", version: "0.2.1" }));
    });
    occupied.port = await listen(occupiedServer);
    const occupiedResult = await runLauncher(occupied.root, occupied.port);
    assert.notEqual(occupiedResult.status, 0);
    assert.match(
      `${occupiedResult.stdout}\n${occupiedResult.stderr}`,
      /not the installed Vision Bridge|refusing to stop or reuse owners/i,
      "a spoofed healthy response must not be reused",
    );
    await close(occupiedServer);
    occupiedServer = null;

    unknownServer = http.createServer((req, res) => {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true, service: "unrelated-service" }));
    });
    await stopOwnedProcesses(diagnosticCase.root);
    await waitForPortClosed(diagnosticCase.port);
    const unknownPort = await listenAt(unknownServer, diagnosticCase.port);
    const unknownRestart = runRestart(diagnosticCase.root, unknownPort, "https://new.example/v1");
    assert.notEqual(unknownRestart.status, 0);
    assert.match(
      unknownRestart.stdout + "\n" + unknownRestart.stderr,
      /not the installed Vision Bridge|not node\.exe|owner/i,
    );
    assert.equal(await isPortListening(unknownPort), true);
    await close(unknownServer);
    unknownServer = null;

    const delayedBridgeDir = createBundle(delayed.root);
    fs.writeFileSync(path.join(delayedBridgeDir, "vision-bridge.js"), [
      'const http = require("node:http");',
      'const port = Number(process.env.BRIDGE_PORT);',
      'http.createServer((req, res) => {',
      '  if (req.url === "/health") { setTimeout(() => res.end("not ready"), 5000); return; }',
      '  res.end("ok");',
      '}).listen(port, "127.0.0.1");',
    ].join("\n"));
    const delayedResult = await runLauncher(delayed.root, delayed.port, { BRIDGE_STARTUP_TIMEOUT_MS: "1000" });
    assert.notEqual(delayedResult.status, 0);
    assert.match(
      `${delayedResult.stdout}\n${delayedResult.stderr}`,
      /Vision Bridge (?:did not pass health check within 1000 ms|exited during startup)/i,
      "delayed startup must fail within the configured health-check deadline",
    );
    await new Promise((resolve) => setTimeout(resolve, 200));
    assert.equal(await isPortListening(delayed.port), false, "timed-out bridge process must be stopped");

    vbsRegistryPath = registryTestPath + "-vbs";
    setRegistryValue(vbsRegistryPath, "CC Switch", originalCCSwitchCommand);
    const vbsInstallResult = runInstaller(vbsCase.root, vbsStartup, [
      "-CCSwitchRunKeyPath",
      vbsRegistryPath,
    ]);
    assert.equal(vbsInstallResult.status, 0, `${vbsInstallResult.stdout}\n${vbsInstallResult.stderr}`);
    const vbsResult = runStartupVbs(vbsCase.root, vbsStartup, vbsCase.port);
    assert.equal(vbsResult.status, 0, `${vbsResult.stdout}\n${vbsResult.stderr}`);
    const vbsHealth = await waitForHealthy(
      vbsCase.port,
      "startup-test-token",
      10000,
      path.join(vbsCase.root, ".claude", "bridge", "vision-bridge.err.log"),
    );
    assert.equal(vbsHealth.body.service, "vision-bridge");
    assert.match(getRegistryValue(vbsRegistryPath, "CC Switch"), /start-ccswitch-after-bridge\.vbs/);
    const vbsRestoreResult = runRestore(vbsCase.root, vbsRegistryPath);
    assert.equal(
      vbsRestoreResult.status,
      0,
      vbsRestoreResult.stdout + "\n" + vbsRestoreResult.stderr,
    );
    assert.equal(getRegistryValue(vbsRegistryPath, "CC Switch"), originalCCSwitchCommand);
    removeRegistryKey(vbsRegistryPath);
    vbsRegistryPath = "";

    createBundle(coordinatorCase.root);
    coordinatorCase.marker = path.join(coordinatorCase.root, "cc-switch-started.txt");
    const markerScript = path.join(coordinatorCase.root, "mark-cc-switch-started.ps1");
    fs.writeFileSync(
      markerScript,
      "Set-Content -LiteralPath '" + coordinatorCase.marker.replace(/'/g, "''") + "' -Value started -Encoding UTF8",
      "utf8",
    );
    const coordinatorCommandPath = path.join(
      coordinatorCase.root,
      ".claude",
      "bridge",
      "cc-switch-startup.command",
    );
    const powershellPath = path.join(
      process.env.SystemRoot || "C:\\Windows",
      "System32",
      "WindowsPowerShell",
      "v1.0",
      "powershell.exe",
    );
    fs.writeFileSync(
      coordinatorCommandPath,
      '"' + powershellPath + '" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + markerScript + '"',
      "utf16le",
    );
    coordinatorProcess = runCCSwitchCoordinator(coordinatorCase.root, coordinatorCase.port);
    await new Promise((resolve) => setTimeout(resolve, 500));
    assert.equal(
      fs.existsSync(coordinatorCase.marker),
      false,
      "CC Switch command must wait for the bridge health check",
    );
    coordinatorCase.healthReady = true;
    await waitForFile(coordinatorCase.marker);
    const coordinatorExit = await waitForChildExit(coordinatorProcess);
    assert.equal(coordinatorExit.code, 0);

    await removeFileWithRetry(coordinatorCase.marker);
    coordinatorCase.healthReady = false;
    const timeoutProcess = runCCSwitchCoordinator(coordinatorCase.root, coordinatorCase.port, 1000);
    const timeoutExit = await waitForChildExit(timeoutProcess);
    assert.equal(timeoutExit.code, 1);
    assert.equal(
      fs.existsSync(coordinatorCase.marker),
      false,
      "CC Switch must not start after coordinator timeout",
    );

    console.log("startup script smoke test: PASS");
  } finally {
    if (occupiedServer) await close(occupiedServer);
    if (coordinatorProcess && coordinatorProcess.exitCode === null) {
      coordinatorProcess.kill();
    }
    await close(coordinatorHealth);
    if (unknownServer) await close(unknownServer);
    await close(upstreamOld.server);
    await close(upstreamNew.server);
    await close(visionOld.server);
    await close(visionNew.server);
    removeRegistryKey(registryTestPath);
    if (vbsRegistryPath) removeRegistryKey(vbsRegistryPath);
    fs.rmSync(installRoot, { recursive: true, force: true });
    await removeTree(normal);
    await removeTree(occupied);
    await removeTree(delayed);
    await removeTree(restartCase);
    await removeTree(diagnosticCase);
    await removeTree(vbsCase);
    await removeTree(coordinatorCase);
  }
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exitCode = 1;
});
