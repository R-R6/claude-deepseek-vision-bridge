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

const sourceDir = path.join(__dirname, "..", "src");
const powershell = "powershell.exe";

function trace(message) {
  if (process.env.STARTUP_SMOKE_TRACE === "1") {
    console.error(`[startup smoke] ${message}`);
  }
}

function listen(server) {
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server.address().port)));
}

function close(server) {
  return new Promise((resolve) => server.close(resolve));
}

function getJson(port, urlPath, headers = {}) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      callback(value);
    };
    const request = http.get({ host: "127.0.0.1", port, path: urlPath, headers }, (res) => {
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

function freePort() {
  const probe = http.createServer();
  return listen(probe).then((port) => close(probe).then(() => port));
}

function createBundle(homeDir) {
  const bridgeDir = path.join(homeDir, ".claude", "bridge");
  fs.mkdirSync(bridgeDir, { recursive: true });
  for (const name of [
    "vision-bridge.js",
    "vision-client.js",
    "start-vision-bridge.ps1",
    "start-ccswitch-after-bridge.vbs",
  ]) {
    fs.copyFileSync(path.join(sourceDir, name), path.join(bridgeDir, name));
  }
  return bridgeDir;
}

function runLauncher(homeDir, port, extraEnv = {}) {
  const launcher = path.join(homeDir, ".claude", "bridge", "start-vision-bridge.ps1");
  return spawnSync(powershell, [
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
      VISION_API_KEY: "startup-test-key",
      BRIDGE_STARTUP_TIMEOUT_MS: "5000",
      ...extraEnv,
    },
    encoding: "utf8",
    timeout: 15000,
  });
}

function runInstaller(homeDir, startupDir, extraArgs = []) {
  return spawnSync(powershell, [
    "-NoLogo",
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    path.join(sourceDir, "install-vision-bridge.ps1"),
    "-InstallUserProfile",
    homeDir,
    "-StartupDirectory",
    startupDir,
    ...extraArgs,
  ], { encoding: "utf8", timeout: 15000 });
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
  return spawnSync(powershell, [
    "-NoLogo",
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    path.join(sourceDir, "restore-ccswitch-startup.ps1"),
    "-InstallUserProfile",
    homeDir,
    "-CCSwitchRunKeyPath",
    keyPath,
  ], { encoding: "utf8", timeout: 15000 });
}

function runStartupVbs(homeDir, startupDir, port) {
  const cscript = path.join(process.env.SystemRoot || "C:\\Windows", "System32", "cscript.exe");
  return spawnSync(cscript, ["//nologo", path.join(startupDir, "vision-bridge.vbs")], {
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

function waitForChildExit(child) {
  return new Promise((resolve, reject) => {
    if (child.exitCode !== null) {
      resolve({ code: child.exitCode, signal: child.signalCode });
      return;
    }
    child.once("error", reject);
    child.once("exit", (code, signal) => resolve({ code, signal }));
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
    const request = http.get({ host: "127.0.0.1", port, path: "/health" }, (res) => {
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
      ".claude/bridge/start-ccswitch-after-bridge.vbs",
      ".claude/bridge/restore-ccswitch-startup.ps1",
      ".claude/bridge/diagnose-vision-bridge.ps1",
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

    createBundle(normal.root);
    const normalResult = runLauncher(normal.root, normal.port);
    assert.equal(normalResult.status, 0, `${normalResult.stdout}\n${normalResult.stderr}`);
    assert.match(normalResult.stdout, /passed health check/);
    const normalHealth = await getJson(normal.port, "/health", { "x-bridge-token": "startup-test-token" });
    assert.equal(normalHealth.status, 200);
    assert.equal(normalHealth.body.version, "0.2.1");
    await stopOwnedProcesses(normal.root);

    const occupiedBundle = createBundle(occupied.root);
    occupiedServer = http.createServer((req, res) => {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true, service: "unrelated-service" }));
    });
    occupied.port = await listen(occupiedServer);
    const occupiedResult = runLauncher(occupied.root, occupied.port);
    assert.notEqual(occupiedResult.status, 0);
    assert.match(`${occupiedResult.stdout}\n${occupiedResult.stderr}`, /not a healthy Vision Bridge version/);
    await close(occupiedServer);
    occupiedServer = null;

    const delayedBridgeDir = createBundle(delayed.root);
    fs.writeFileSync(path.join(delayedBridgeDir, "vision-bridge.js"), [
      'const http = require("node:http");',
      'const port = Number(process.env.BRIDGE_PORT);',
      'http.createServer((req, res) => {',
      '  if (req.url === "/health") { setTimeout(() => res.end("not ready"), 5000); return; }',
      '  res.end("ok");',
      '}).listen(port, "127.0.0.1");',
    ].join("\n"));
    const delayedResult = runLauncher(delayed.root, delayed.port, { BRIDGE_STARTUP_TIMEOUT_MS: "1000" });
    assert.notEqual(delayedResult.status, 0);
    assert.match(`${delayedResult.stdout}\n${delayedResult.stderr}`, /did not pass health check within 1000 ms/);
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

    fs.rmSync(coordinatorCase.marker, { force: true });
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
    removeRegistryKey(registryTestPath);
    if (vbsRegistryPath) removeRegistryKey(vbsRegistryPath);
    fs.rmSync(installRoot, { recursive: true, force: true });
    await removeTree(normal);
    await removeTree(occupied);
    await removeTree(delayed);
    await removeTree(vbsCase);
    await removeTree(coordinatorCase);
  }
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exitCode = 1;
});
