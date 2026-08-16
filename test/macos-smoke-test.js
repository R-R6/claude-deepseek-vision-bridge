#!/usr/bin/env node
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");

if (process.platform !== "darwin") {
  console.log("macOS smoke test: SKIP (macOS only)");
  process.exit(0);
}

const sourceRoot = path.join(__dirname, "..", "src");
const coreDir = path.join(sourceRoot, "core");
const routingDir = path.join(sourceRoot, "routing");
const macosDir = path.join(sourceRoot, "macos");
const nodePath = process.execPath;
const ccSwitchProcessRunning = process.platform === "darwin"
  && run("/usr/bin/pgrep", ["-x", "cc-switch"]).status === 0;

function getDatabaseSync() {
  try {
    return require("node:sqlite").DatabaseSync;
  } catch {
    return null;
  }
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    ...options,
  });
  if (result.error) throw result.error;
  return result;
}

function runAsync(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      ...options,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.once("error", reject);
    child.once("close", (status, signal) => resolve({ status, signal, stdout, stderr }));
  });
}

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.removeListener("error", reject);
      resolve(server.address().port);
    });
  });
}

function close(server) {
  return new Promise((resolve, reject) => {
    server.close((error) => {
      if (error && error.code !== "ERR_SERVER_NOT_RUNNING") reject(error);
      else resolve();
    });
  });
}

function getJson(port, urlPath = "/health") {
  return new Promise((resolve, reject) => {
    const request = http.get({ host: "127.0.0.1", port, path: urlPath, agent: false }, (response) => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => { body += chunk; });
      response.on("error", reject);
      response.on("end", () => {
        try {
          resolve({ status: response.statusCode, body: JSON.parse(body) });
        } catch (error) {
          reject(error);
        }
      });
    });
    request.setTimeout(1000, () => request.destroy(new Error("health request timed out")));
    request.on("error", reject);
  });
}

async function waitForHealth(port, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const result = await getJson(port);
      if (result.status === 200 && result.body?.ok === true && result.body?.version === "0.2.1") return;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`bridge did not become healthy on port ${port}`);
}

function createRouteDatabase(DatabaseSync, databasePath) {
  const database = new DatabaseSync(databasePath);
  try {
    database.exec(`
      CREATE TABLE providers (
        id TEXT NOT NULL,
        app_type TEXT NOT NULL,
        settings_config TEXT NOT NULL,
        is_current INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (id, app_type)
      );
    `);
    database.prepare(
      "INSERT INTO providers (id, app_type, settings_config, is_current) VALUES (?, ?, ?, 1)",
    ).run(
      "provider-1",
      "claude-desktop",
      JSON.stringify({
        env: {
          ANTHROPIC_BASE_URL: "https://text.example/v1",
          ANTHROPIC_AUTH_TOKEN: "mac-route-test-secret",
        },
      }),
    );
  } finally {
    database.close();
  }
}

function readRoute(DatabaseSync, databasePath) {
  const database = new DatabaseSync(databasePath);
  try {
    return database.prepare(
      "SELECT json_extract(settings_config, '$.env.ANTHROPIC_BASE_URL') AS route FROM providers",
    ).get().route;
  } finally {
    database.close();
  }
}

function readProviderValue(DatabaseSync, databasePath, jsonPath) {
  const database = new DatabaseSync(databasePath);
  try {
    return database.prepare(
      "SELECT json_extract(settings_config, ?) AS value FROM providers",
    ).get(jsonPath).value;
  } finally {
    database.close();
  }
}

function writeExecutable(filePath, content) {
  fs.writeFileSync(filePath, content, { mode: 0o755 });
  fs.chmodSync(filePath, 0o755);
}

function writeFakeLaunchctl(filePath) {
  writeExecutable(filePath, String.raw`#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$FAKE_LAUNCHCTL_LOG"
case "$1" in
  print)
    [ -f "$FAKE_LAUNCHCTL_LOADED" ]
    ;;
  bootout)
    rm -f "$FAKE_LAUNCHCTL_LOADED"
    exit 0
    ;;
  kickstart)
    [ -f "$FAKE_LAUNCHCTL_LOADED" ]
    ;;
  bootstrap)
    count=0
    if [ -f "$FAKE_LAUNCHCTL_COUNT" ]; then
      count=$(cat "$FAKE_LAUNCHCTL_COUNT")
    fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$FAKE_LAUNCHCTL_COUNT"
    failures=\${FAKE_LAUNCHCTL_BOOTSTRAP_FAILURES:-0}
    if [ "$count" -le "$failures" ]; then
      exit 1
    fi
    : > "$FAKE_LAUNCHCTL_LOADED"
    exit 0
    ;;
  *) exit 1 ;;
esac
`);
}

function writeInterruptingLaunchctl(filePath) {
  writeExecutable(filePath, String.raw`#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$FAKE_LAUNCHCTL_LOG"
case "$1" in
  print|kickstart) exit 0 ;;
  bootout)
    if [ ! -f "$FAKE_LAUNCHCTL_INTERRUPTED" ]; then
      : > "$FAKE_LAUNCHCTL_INTERRUPTED"
      kill -TERM "$PPID"
    fi
    exit 0
    ;;
  bootstrap) exit 0 ;;
  *) exit 1 ;;
esac
`);
}

function writeManagedLaunchctl(filePath) {
  writeExecutable(filePath, String.raw`#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$FAKE_LAUNCHCTL_LOG"
state="$FAKE_LAUNCHCTL_STATE"
stop_bridge() {
  if [ -f "$state" ]; then
    pid=$(cat "$state")
    kill "$pid" 2>/dev/null || true
    rm -f "$state"
  fi
}
start_bridge() {
  stop_bridge
  sh "$BRIDGE_DIR/start-vision-bridge.sh" --foreground >> "$FAKE_LAUNCHCTL_BRIDGE_LOG" 2>&1 &
  printf '%s\n' "$!" > "$state"
}
case "$1" in
  print)
    if [ -f "$state" ] && kill -0 "$(cat "$state")" 2>/dev/null; then exit 0; fi
    rm -f "$state"
    exit 1
    ;;
  bootout) stop_bridge; exit 0 ;;
  bootstrap)
    if [ "\${FAKE_LAUNCHCTL_FAIL_NEXT_BOOTSTRAP:-0}" = 1 ] &&
        [ ! -f "$FAKE_LAUNCHCTL_BOOTSTRAP_FAILED_MARKER" ]; then
      : > "$FAKE_LAUNCHCTL_BOOTSTRAP_FAILED_MARKER"
      exit 1
    fi
    start_bridge
    exit 0
    ;;
  kickstart)
    if [ "\${2:-}" = -k ]; then stop_bridge; fi
    start_bridge
    exit 0
    ;;
  *) exit 1
    ;;
esac
`);
}

async function main() {
  const DatabaseSync = getDatabaseSync();
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "vision bridge mac-"));
  const home = path.join(root, "Home With Spaces");
  const envFile = path.join(root, "bridge.env");
  const routeDir = path.join(root, ".cc-switch");
  const databasePath = path.join(routeDir, "cc-switch.db");
  const settingsPath = path.join(routeDir, "settings.json");
  const backupDirectory = path.join(root, "route-backup");
  const authenticatedBackupDirectory = path.join(root, "authenticated-route-backup");
  const restoreBackupDirectory = path.join(root, "restore-route-backup");
  const authenticatedBridgeEnvFile = path.join(root, "authenticated-bridge.env");
  const ccSwitchAppPath = path.join(root, "CC Switch.app");
  fs.mkdirSync(home, { recursive: true });
  fs.mkdirSync(routeDir, { recursive: true });
  fs.mkdirSync(ccSwitchAppPath, { recursive: true });

  const healthServer = http.createServer((request, response) => {
    if (request.url === "/health") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ ok: true, service: "vision-bridge", version: "0.2.1" }));
      return;
    }
    response.writeHead(404);
    response.end();
  });
  const healthPort = await listen(healthServer);
  const bridgeAuthToken = "mac-route-health-token";
  let receivedBridgeAuthToken = "";
  const authenticatedHealthServer = http.createServer((request, response) => {
    receivedBridgeAuthToken = request.headers["x-bridge-token"] || "";
    if (request.url !== "/health" || receivedBridgeAuthToken !== bridgeAuthToken) {
      response.writeHead(401);
      response.end();
      return;
    }
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ ok: true, service: "vision-bridge", version: "0.2.1" }));
  });
  const authenticatedHealthPort = await listen(authenticatedHealthServer);
  let receivedVisionAuthorization = "";
  const visionServer = http.createServer((request, response) => {
    receivedVisionAuthorization = request.headers.authorization || "";
    if (request.method !== "POST" || request.url !== "/v1/chat/completions") {
      response.writeHead(404);
      response.end();
      return;
    }
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({
      choices: [{ message: { content: "macOS Vision Skill response" } }],
    }));
  });
  const visionPort = await listen(visionServer);
  const bridgeProbe = http.createServer();
  const bridgePort = await listen(bridgeProbe);
  await close(bridgeProbe);
  if (DatabaseSync) {
    fs.writeFileSync(settingsPath, JSON.stringify({ currentProviderClaudeDesktop: "provider-1" }), "utf8");
    createRouteDatabase(DatabaseSync, databasePath);
    fs.writeFileSync(authenticatedBridgeEnvFile, `BRIDGE_AUTH_TOKEN=${bridgeAuthToken}\n`, { mode: 0o600 });
  }
  fs.writeFileSync(envFile, [
    "UPSTREAM=http://127.0.0.1:1/v1",
    `VISION_BASE_URL=http://127.0.0.1:${visionPort}/v1`,
    "VISION_MODEL=test-vision",
    "VISION_API_KEY=mac-startup-test-secret",
    "BRIDGE_HOST=127.0.0.1",
    `BRIDGE_PORT=${bridgePort}`,
    "BRIDGE_STARTUP_TIMEOUT_MS=1000",
    `BRIDGE_NODE=${nodePath}`,
  ].join("\n") + "\n", { mode: 0o600 });

  let bridgeProcess;
  try {
    for (const script of [
      "start-vision-bridge.sh",
      "restart-vision-bridge.sh",
      "diagnose-vision-bridge.sh",
      "install-vision-bridge.sh",
      "start-ccswitch-after-bridge.sh",
      "vision.sh",
    ]) {
      assert.equal(run("sh", ["-n", path.join(macosDir, script)]).status, 0, script);
    }

    const sourceVisionResult = await runAsync("sh", [
      path.join(macosDir, "vision.sh"),
      "--url", "https://example.com/source-layout.png", "verify source layout",
    ], {
      env: {
        ...process.env,
        BRIDGE_ENV_FILE: envFile,
        BRIDGE_NODE: nodePath,
      },
    });
    assert.equal(sourceVisionResult.status, 0, `${sourceVisionResult.stdout}\n${sourceVisionResult.stderr}`);
    assert.match(sourceVisionResult.stdout, /macOS Vision Skill response/);

    const missingConfigHome = path.join(root, "Missing Config Home");
    fs.mkdirSync(missingConfigHome, { recursive: true });
    const missingConfigResult = run("sh", [
      path.join(macosDir, "install-vision-bridge.sh"),
    ], { env: { ...process.env, HOME: missingConfigHome } });
    assert.notEqual(missingConfigResult.status, 0);
    assert.match(`${missingConfigResult.stdout}\n${missingConfigResult.stderr}`, /--env-file is required/);

    const incompleteEnvFile = path.join(root, "incomplete-bridge.env");
    fs.writeFileSync(incompleteEnvFile, [
      "UPSTREAM=https://text.example/v1",
      "VISION_BASE_URL=https://vision.example/v1",
      "VISION_API_KEY=test-secret",
    ].join("\n") + "\n", { mode: 0o600 });
    const incompleteInstallHome = path.join(root, "Incomplete Config Home");
    const incompleteInstallResult = run("sh", [
      path.join(macosDir, "install-vision-bridge.sh"),
      "--env-file", incompleteEnvFile,
      "--skip-launchctl",
    ], { env: { ...process.env, HOME: incompleteInstallHome } });
    assert.notEqual(incompleteInstallResult.status, 0);
    assert.match(`${incompleteInstallResult.stdout}\n${incompleteInstallResult.stderr}`, /VISION_MODEL is not configured/);
    assert.equal(fs.existsSync(path.join(incompleteInstallHome, ".claude", "bridge")), false);

    const whitespaceEnvFile = path.join(root, "whitespace-bridge.env");
    fs.writeFileSync(whitespaceEnvFile, [
      "UPSTREAM=https://text.example/v1",
      "VISION_BASE_URL=https://vision.example/v1",
      "VISION_API_KEY=test-secret",
      "VISION_MODEL=   ",
    ].join("\n") + "\n", { mode: 0o600 });
    const whitespaceInstallHome = path.join(root, "Whitespace Config Home");
    const whitespaceInstallResult = run("sh", [
      path.join(macosDir, "install-vision-bridge.sh"),
      "--env-file", whitespaceEnvFile,
      "--skip-launchctl",
    ], { env: { ...process.env, HOME: whitespaceInstallHome } });
    assert.notEqual(whitespaceInstallResult.status, 0);
    assert.match(`${whitespaceInstallResult.stdout}\n${whitespaceInstallResult.stderr}`, /VISION_MODEL is not configured/);
    assert.equal(fs.existsSync(path.join(whitespaceInstallHome, ".claude", "bridge")), false);

    const insecureEnvFile = path.join(root, "insecure-bridge.env");
    fs.writeFileSync(insecureEnvFile, [
      "UPSTREAM=http://text.example/v1",
      "VISION_BASE_URL=https://vision.example/v1",
      "VISION_API_KEY=test-secret",
      "VISION_MODEL=test-vision-model",
    ].join("\n") + "\n", { mode: 0o600 });
    const insecureInstallHome = path.join(root, "Insecure Config Home");
    const insecureInstallResult = run("sh", [
      path.join(macosDir, "install-vision-bridge.sh"),
      "--env-file", insecureEnvFile,
      "--skip-launchctl",
    ], { env: { ...process.env, HOME: insecureInstallHome } });
    assert.notEqual(insecureInstallResult.status, 0);
    assert.match(`${insecureInstallResult.stdout}\n${insecureInstallResult.stderr}`, /UPSTREAM must use https/);
    assert.equal(fs.existsSync(path.join(insecureInstallHome, ".claude", "bridge")), false);

    for (const [missingName, extraEnvironment] of [
      ["VISION_BASE_URL", { VISION_BASE_URL: "" }],
      ["VISION_MODEL", { VISION_MODEL: "" }],
    ]) {
      const missingRequiredResult = run("sh", [
        path.join(macosDir, "start-vision-bridge.sh"),
      ], {
        env: {
          ...process.env,
          BRIDGE_DIR: coreDir,
          BRIDGE_SCRIPT: path.join(coreDir, "vision-bridge.js"),
          BRIDGE_ENV_FILE: path.join(root, "missing-environment-file"),
          BRIDGE_NODE: nodePath,
          UPSTREAM: "https://text.example/v1",
          VISION_API_KEY: "test-secret",
          VISION_BASE_URL: "https://vision.example/v1",
          VISION_MODEL: "test-vision-model",
          ...extraEnvironment,
        },
      });
      assert.notEqual(missingRequiredResult.status, 0);
      assert.match(
        `${missingRequiredResult.stdout}\n${missingRequiredResult.stderr}`,
        new RegExp(`${missingName} is not configured`),
      );
    }

    const fakeNodeDirectory = path.join(root, "fake-node-bin");
    const legacyNodePath = path.join(fakeNodeDirectory, "node");
    fs.mkdirSync(fakeNodeDirectory, { recursive: true });
    writeExecutable(legacyNodePath, String.raw`#!/bin/sh
if [ "$1" = "-p" ] && [ "$2" = "process.execPath" ]; then
  printf '%s\n' "$0"
  exit 0
fi
printf '%s\n' "17"
`);
    const legacyNodeResult = run("sh", [
      path.join(macosDir, "install-vision-bridge.sh"),
      "--skip-launchctl",
    ], {
      env: {
        ...process.env,
        HOME: path.join(root, "Legacy Node Home"),
        PATH: `${fakeNodeDirectory}:${process.env.PATH}`,
      },
    });
    assert.notEqual(legacyNodeResult.status, 0);
    assert.match(`${legacyNodeResult.stdout}\n${legacyNodeResult.stderr}`, /Node\.js 18\+ is required/);

    const rollbackHome = path.join(root, "Rollback Home");
    const rollbackLaunchAgents = path.join(rollbackHome, "Library", "LaunchAgents");
    const rollbackPlist = path.join(rollbackLaunchAgents, "com.claude.deepseek-vision-bridge.plist");
    const originalRollbackPlist = "old launch agent contents\n";
    const fakeLaunchctlDirectory = path.join(root, "fake-launchctl-bin");
    const fakeLaunchctlLog = path.join(root, "fake-launchctl.log");
    const fakeLaunchctlCount = path.join(root, "fake-launchctl.count");
    const fakeLaunchctlLoaded = path.join(root, "fake-launchctl.loaded");
    fs.mkdirSync(rollbackLaunchAgents, { recursive: true });
    fs.mkdirSync(fakeLaunchctlDirectory, { recursive: true });
    fs.writeFileSync(rollbackPlist, originalRollbackPlist, "utf8");
    fs.writeFileSync(fakeLaunchctlLoaded, "", "utf8");
    writeFakeLaunchctl(path.join(fakeLaunchctlDirectory, "launchctl"));
    const rollbackResult = run("sh", [
      path.join(macosDir, "install-vision-bridge.sh"),
      "--env-file", envFile,
      "--bridge-port", String(bridgePort),
    ], {
      env: {
        ...process.env,
        HOME: rollbackHome,
        PATH: `${fakeLaunchctlDirectory}:${process.env.PATH}`,
        FAKE_LAUNCHCTL_LOG: fakeLaunchctlLog,
        FAKE_LAUNCHCTL_COUNT: fakeLaunchctlCount,
        FAKE_LAUNCHCTL_LOADED: fakeLaunchctlLoaded,
        FAKE_LAUNCHCTL_BOOTSTRAP_FAILURES: "6",
      },
    });
    assert.notEqual(rollbackResult.status, 0);
    assert.equal(fs.readFileSync(rollbackPlist, "utf8"), originalRollbackPlist);
    const rollbackCalls = fs.readFileSync(fakeLaunchctlLog, "utf8");
    assert.equal((rollbackCalls.match(/^bootstrap /gm) || []).length, 7);
    assert.match(rollbackCalls, /^bootout /m);
    assert.match(rollbackCalls, /^kickstart /m);

    const interruptHome = path.join(root, "Interrupted Install Home");
    const interruptLaunchAgents = path.join(interruptHome, "Library", "LaunchAgents");
    const interruptPlist = path.join(interruptLaunchAgents, "com.claude.deepseek-vision-bridge.plist");
    const interruptBin = path.join(root, "interrupt-launchctl-bin");
    const interruptLog = path.join(root, "interrupt-launchctl.log");
    const interruptMarker = path.join(root, "interrupt-launchctl.marker");
    const originalInterruptPlist = "old interrupted launch agent contents\n";
    fs.mkdirSync(interruptLaunchAgents, { recursive: true });
    fs.mkdirSync(interruptBin, { recursive: true });
    fs.writeFileSync(interruptPlist, originalInterruptPlist, "utf8");
    writeInterruptingLaunchctl(path.join(interruptBin, "launchctl"));
    const interruptResult = run("sh", [
      path.join(macosDir, "install-vision-bridge.sh"),
      "--env-file", envFile,
      "--bridge-port", String(bridgePort),
    ], {
      env: {
        ...process.env,
        HOME: interruptHome,
        PATH: `${interruptBin}:${process.env.PATH}`,
        FAKE_LAUNCHCTL_LOG: interruptLog,
        FAKE_LAUNCHCTL_INTERRUPTED: interruptMarker,
      },
    });
    assert.notEqual(interruptResult.status, 0);
    assert.equal(fs.readFileSync(interruptPlist, "utf8"), originalInterruptPlist);
    const interruptCalls = fs.readFileSync(interruptLog, "utf8");
    assert.equal((interruptCalls.match(/^bootstrap /gm) || []).length, 1);
    assert.match(interruptCalls, /^bootout /m);

    const installer = run("sh", [
      path.join(macosDir, "install-vision-bridge.sh"),
      "--env-file", envFile,
      "--bridge-port", String(bridgePort),
      "--ccswitch-directory", routeDir,
      "--ccswitch-app", ccSwitchAppPath,
      "--app-type", "claude-desktop",
      "--coordinate-ccswitch-startup",
      "--skip-launchctl",
    ], { env: { ...process.env, HOME: home } });
    assert.equal(installer.status, 0, `${installer.stdout}\n${installer.stderr}`);
    assert.doesNotMatch(`${installer.stdout}\n${installer.stderr}`, /mac-startup-test-secret/);

    const bridgeDir = path.join(home, ".claude", "bridge");
    const launchAgent = path.join(home, "Library", "LaunchAgents", "com.claude.deepseek-vision-bridge.plist");
    const coordinatorLaunchAgent = path.join(home, "Library", "LaunchAgents", "com.claude.deepseek-vision-bridge.cc-switch.plist");
    for (const relativePath of [
      ".claude/bridge/vision-bridge.js",
      ".claude/bridge/vision-client.js",
      ".claude/bridge/bridge-health.js",
      ".claude/bridge/start-vision-bridge.sh",
      ".claude/bridge/bridge-rollback-state.sh",
      ".claude/bridge/restart-vision-bridge.sh",
      ".claude/bridge/reinstall-vision-bridge.sh",
      ".claude/bridge/install-vision-bridge.sh",
      ".claude/bridge/SKILL.md.template",
      ".claude/bridge/diagnose-vision-bridge.sh",
      ".claude/bridge/configure-ccswitch-route.js",
      ".claude/bridge/configure-ccswitch-route.sh",
      ".claude/bridge/bridge.env",
      ".claude/skills/vision/vision.js",
      ".claude/skills/vision/vision.sh",
      ".claude/skills/vision/SKILL.md",
    ]) {
      assert.equal(fs.existsSync(path.join(home, relativePath)), true, relativePath);
    }
    assert.equal(run("plutil", ["-lint", launchAgent]).status, 0);
    assert.equal(run("plutil", ["-lint", coordinatorLaunchAgent]).status, 0);
    assert.doesNotMatch(fs.readFileSync(launchAgent, "utf8"), /mac-startup-test-secret/);
    assert.doesNotMatch(fs.readFileSync(coordinatorLaunchAgent, "utf8"), /mac-startup-test-secret/);
    assert.equal((fs.statSync(path.join(bridgeDir, "bridge.env")).mode & 0o077), 0);
    assert.notEqual(fs.statSync(path.join(home, ".claude", "skills", "vision", "vision.sh")).mode & 0o111, 0);
    const routeRejectedByReinstall = run("sh", [
      path.join(bridgeDir, "reinstall-vision-bridge.sh"),
      "--configure-ccswitch-route",
    ], { env: { ...process.env, HOME: home } });
    assert.equal(routeRejectedByReinstall.status, 2);
    assert.match(
      `${routeRejectedByReinstall.stdout}\n${routeRejectedByReinstall.stderr}`,
      /does not modify CC Switch routes/,
    );
    const installedReinstall = run("sh", [
      path.join(bridgeDir, "reinstall-vision-bridge.sh"),
      "--skip-launchctl",
    ], { env: { ...process.env, HOME: home } });
    assert.equal(installedReinstall.status, 0, `${installedReinstall.stdout}\n${installedReinstall.stderr}`);

    const managedLaunchctlDirectory = path.join(root, "managed-launchctl-bin");
    const managedLaunchctlLog = path.join(root, "managed-launchctl.log");
    const managedBridgeLog = path.join(root, "managed-bridge.log");
    const managedLaunchctlState = path.join(root, "managed-launchctl.state");
    const managedBootstrapFailureMarker = path.join(root, "managed-bootstrap-failure.marker");
    fs.mkdirSync(managedLaunchctlDirectory, { recursive: true });
    writeManagedLaunchctl(path.join(managedLaunchctlDirectory, "launchctl"));
    const managedEnvironment = {
      ...process.env,
      HOME: home,
      BRIDGE_DIR: bridgeDir,
      BRIDGE_ENV_FILE: path.join(bridgeDir, "bridge.env"),
      BRIDGE_PLIST: launchAgent,
      BRIDGE_NODE: nodePath,
      PATH: `${managedLaunchctlDirectory}:${process.env.PATH}`,
      FAKE_LAUNCHCTL_LOG: managedLaunchctlLog,
      FAKE_LAUNCHCTL_BRIDGE_LOG: managedBridgeLog,
      FAKE_LAUNCHCTL_STATE: managedLaunchctlState,
      FAKE_LAUNCHCTL_BOOTSTRAP_FAILED_MARKER: managedBootstrapFailureMarker,
    };
    const launchDomain = `gui/${process.getuid()}`;
    assert.equal(
      run(path.join(managedLaunchctlDirectory, "launchctl"), ["bootstrap", launchDomain, launchAgent], {
        env: managedEnvironment,
      }).status,
      0,
    );
    await waitForHealth(bridgePort);
    const healthyRestart = await runAsync("sh", [path.join(bridgeDir, "restart-vision-bridge.sh")], {
      env: managedEnvironment,
    });
    assert.equal(healthyRestart.status, 0, `${healthyRestart.stdout}\n${healthyRestart.stderr}`);
    assert.match(healthyRestart.stdout, /passed health check/);
    assert.equal(fs.existsSync(path.join(bridgeDir, "rollback", "current")), true);

    const bridgeScriptPath = path.join(bridgeDir, "vision-bridge.js");
    const healthyBridgeScript = fs.readFileSync(bridgeScriptPath, "utf8");
    fs.writeFileSync(bridgeScriptPath, "this is not valid JavaScript\n", "utf8");
    const bootstrapCallsBeforeRollback = (fs.readFileSync(managedLaunchctlLog, "utf8").match(/^bootstrap /gm) || []).length;
    managedEnvironment.FAKE_LAUNCHCTL_FAIL_NEXT_BOOTSTRAP = "1";
    const failedRestart = await runAsync("sh", [path.join(bridgeDir, "restart-vision-bridge.sh")], {
      env: managedEnvironment,
    });
    assert.notEqual(failedRestart.status, 0);
    assert.match(
      `${failedRestart.stdout}\n${failedRestart.stderr}`,
      /Previous Vision Bridge configuration was restored and passed its health check/,
    );
    assert.equal(fs.readFileSync(bridgeScriptPath, "utf8"), healthyBridgeScript);
    assert.equal(fs.existsSync(managedBootstrapFailureMarker), true);
    assert.equal(
      (fs.readFileSync(managedLaunchctlLog, "utf8").match(/^bootstrap /gm) || []).length,
      bootstrapCallsBeforeRollback + 2,
    );
    await waitForHealth(bridgePort);
    assert.equal(
      run(path.join(managedLaunchctlDirectory, "launchctl"), ["bootout", `${launchDomain}/${"com.claude.deepseek-vision-bridge"}`], {
        env: managedEnvironment,
      }).status,
      0,
    );

    if (DatabaseSync && !ccSwitchProcessRunning) {
      const routeEnvironment = { ...process.env };
      delete routeEnvironment.BRIDGE_AUTH_TOKEN;
      fs.mkdirSync(backupDirectory, { recursive: true, mode: 0o755 });
      fs.chmodSync(backupDirectory, 0o755);
      const routeResult = await runAsync(nodePath, [
        path.join(routingDir, "configure-ccswitch-route.js"),
        "--database", databasePath,
        "--settings", settingsPath,
        "--backup-directory", backupDirectory,
        "--app-type", "claude-desktop",
        "--bridge-port", String(healthPort),
        "--bridge-env-file", path.join(root, "missing-bridge.env"),
      ], { env: routeEnvironment });
      assert.equal(routeResult.status, 0, `${routeResult.stdout}\n${routeResult.stderr}`);
      assert.equal(readRoute(DatabaseSync, databasePath), `http://127.0.0.1:${healthPort}`);
      assert.equal(fs.existsSync(path.join(backupDirectory, "cc-switch.db")), true);
      assert.equal(fs.statSync(backupDirectory).mode & 0o077, 0);
      assert.equal(readRoute(DatabaseSync, path.join(backupDirectory, "cc-switch.db")), "https://text.example/v1");
      assert.equal(readProviderValue(DatabaseSync, databasePath, "$.env.ANTHROPIC_AUTH_TOKEN"), "mac-route-test-secret");
      assert.doesNotMatch(`${routeResult.stdout}\n${routeResult.stderr}`, /mac-route-test-secret/);

      const healthOnlyResult = await runAsync(nodePath, [
        path.join(routingDir, "configure-ccswitch-route.js"),
        "--bridge-port", String(healthPort),
        "--bridge-env-file", path.join(root, "missing-bridge.env"),
        "--health-only",
      ], { env: routeEnvironment });
      assert.equal(healthOnlyResult.status, 0, `${healthOnlyResult.stdout}\n${healthOnlyResult.stderr}`);
      assert.match(healthOnlyResult.stdout, /managed version 0\.2\.1/);

      const authenticatedRouteResult = await runAsync(nodePath, [
        path.join(routingDir, "configure-ccswitch-route.js"),
        "--database", databasePath,
        "--settings", settingsPath,
        "--backup-directory", authenticatedBackupDirectory,
        "--app-type", "claude-desktop",
        "--bridge-port", String(authenticatedHealthPort),
        "--bridge-env-file", authenticatedBridgeEnvFile,
      ], { env: routeEnvironment });
      assert.equal(authenticatedRouteResult.status, 0, `${authenticatedRouteResult.stdout}\n${authenticatedRouteResult.stderr}`);
      assert.equal(receivedBridgeAuthToken, bridgeAuthToken);
      assert.equal(readRoute(DatabaseSync, databasePath), `http://127.0.0.1:${authenticatedHealthPort}`);
      assert.equal(readProviderValue(DatabaseSync, databasePath, "$.env.ANTHROPIC_AUTH_TOKEN"), "mac-route-test-secret");
      assert.doesNotMatch(`${authenticatedRouteResult.stdout}\n${authenticatedRouteResult.stderr}`, /mac-route-health-token|mac-route-test-secret/);

      const wrapperEnvironment = { ...routeEnvironment, BRIDGE_DIR: routingDir };
      const heldDatabase = new DatabaseSync(databasePath);
      try {
        const noOpWhileRunningResult = await runAsync(nodePath, [
          path.join(routingDir, "configure-ccswitch-route.js"),
          "--database", databasePath,
          "--settings", settingsPath,
          "--app-type", "claude-desktop",
          "--bridge-port", String(authenticatedHealthPort),
          "--bridge-env-file", authenticatedBridgeEnvFile,
        ], { env: routeEnvironment });
        assert.equal(
          noOpWhileRunningResult.status,
          0,
          `${noOpWhileRunningResult.stdout}\n${noOpWhileRunningResult.stderr}`,
        );
        assert.match(noOpWhileRunningResult.stdout, /already targets/);
        assert.doesNotMatch(
          `${noOpWhileRunningResult.stdout}\n${noOpWhileRunningResult.stderr}`,
          /mac-route-health-token|mac-route-test-secret/,
        );

        heldDatabase.prepare(
          "UPDATE providers SET settings_config = json_set(settings_config, '$.env.ANTHROPIC_BASE_URL', ?)",
        ).run("https://text.example/v1");
        const refusedWhileRunningResult = await runAsync("sh", [
          path.join(macosDir, "configure-ccswitch-route.sh"),
          "--ccswitch-directory", routeDir,
          "--database", databasePath,
          "--settings", settingsPath,
          "--app-type", "claude-desktop",
          "--bridge-port", String(authenticatedHealthPort),
          "--bridge-env-file", authenticatedBridgeEnvFile,
        ], { env: wrapperEnvironment });
        assert.notEqual(refusedWhileRunningResult.status, 0);
        assert.match(
          `${refusedWhileRunningResult.stdout}\n${refusedWhileRunningResult.stderr}`,
          /CC Switch was not changed|database is in use|route is not/,
        );
        assert.equal(readRoute(DatabaseSync, databasePath), "https://text.example/v1");
      } finally {
        heldDatabase.close();
      }

      const sidecarPath = `${databasePath}-wal`;
      fs.writeFileSync(sidecarPath, "sidecar-lock-test", "utf8");
      const sidecarHandle = fs.openSync(sidecarPath, "r");
      try {
        const sidecarLockResult = await runAsync(nodePath, [
          path.join(routingDir, "configure-ccswitch-route.js"),
          "--database", databasePath,
          "--settings", settingsPath,
          "--app-type", "claude-desktop",
          "--bridge-port", String(authenticatedHealthPort),
          "--bridge-env-file", authenticatedBridgeEnvFile,
        ], { env: routeEnvironment });
        assert.notEqual(sidecarLockResult.status, 0);
        assert.match(
          `${sidecarLockResult.stdout}\n${sidecarLockResult.stderr}`,
          /database is in use|process is running/,
        );
        assert.equal(readRoute(DatabaseSync, databasePath), "https://text.example/v1");
      } finally {
        fs.closeSync(sidecarHandle);
        if (fs.existsSync(sidecarPath)) fs.unlinkSync(sidecarPath);
      }

      const restoreRouteResult = await runAsync(nodePath, [
        path.join(routingDir, "configure-ccswitch-route.js"),
        "--database", databasePath,
        "--settings", settingsPath,
        "--backup-directory", restoreBackupDirectory,
        "--app-type", "claude-desktop",
        "--bridge-port", String(authenticatedHealthPort),
        "--bridge-env-file", authenticatedBridgeEnvFile,
      ], { env: routeEnvironment });
      assert.equal(restoreRouteResult.status, 0, `${restoreRouteResult.stdout}\n${restoreRouteResult.stderr}`);

      const compareBackupResult = await runAsync(nodePath, [
        path.join(routingDir, "configure-ccswitch-route.js"),
        "--database", databasePath,
        "--settings", settingsPath,
        "--app-type", "claude-desktop",
        "--compare-database", path.join(restoreBackupDirectory, "cc-switch.db"),
      ], { env: routeEnvironment });
      assert.equal(compareBackupResult.status, 3, `${compareBackupResult.stdout}\n${compareBackupResult.stderr}`);
      assert.match(compareBackupResult.stderr, /protected backup/);

      const forcedNoOpResult = await runAsync("sh", [
        path.join(macosDir, "configure-ccswitch-route.sh"),
        "--ccswitch-directory", routeDir,
        "--ccswitch-app", path.join(root, "missing-cc-switch.app"),
        "--app-type", "claude-desktop",
        "--bridge-port", String(authenticatedHealthPort),
        "--bridge-env-file", authenticatedBridgeEnvFile,
        "--force-close-ccswitch",
      ], { env: wrapperEnvironment });
      assert.equal(forcedNoOpResult.status, 0, `${forcedNoOpResult.stdout}\n${forcedNoOpResult.stderr}`);
      assert.match(forcedNoOpResult.stdout, /already targets/);

      const aliasStatusResult = await runAsync("sh", [
        path.join(macosDir, "configure-ccswitch-route.sh"),
        "--cc-switch-directory", routeDir,
        "--app-type", "claude-desktop",
        "--status",
      ], { env: wrapperEnvironment });
      assert.equal(aliasStatusResult.status, 0, `${aliasStatusResult.stdout}\n${aliasStatusResult.stderr}`);
      assert.match(aliasStatusResult.stdout, /current route:/);

      const bypassResult = run(nodePath, [
        path.join(routingDir, "configure-ccswitch-route.js"),
        "--skip-health-check",
      ]);
      assert.notEqual(bypassResult.status, 0);

      const malformedDatabasePath = path.join(root, "malformed-cc-switch.db");
      const malformedBackupDirectory = path.join(root, "malformed-route-backup");
      const malformedDatabase = new DatabaseSync(malformedDatabasePath);
      try {
        malformedDatabase.exec(
          "CREATE TABLE providers (id TEXT, app_type TEXT, settings_config TEXT, is_current INTEGER)",
        );
        malformedDatabase.prepare(
          "INSERT INTO providers VALUES (?, ?, ?, 1)",
        ).run("provider-1", "claude-desktop", "{not-valid-json");
      } finally {
        malformedDatabase.close();
      }
      const malformedResult = await runAsync(nodePath, [
        path.join(routingDir, "configure-ccswitch-route.js"),
        "--database", malformedDatabasePath,
        "--settings", settingsPath,
        "--backup-directory", malformedBackupDirectory,
        "--app-type", "claude-desktop",
        "--bridge-port", String(healthPort),
        "--bridge-env-file", path.join(root, "missing-bridge.env"),
      ], { env: routeEnvironment });
      assert.notEqual(malformedResult.status, 0);
      assert.match(`${malformedResult.stdout}\n${malformedResult.stderr}`, /not valid JSON/);
      assert.equal(fs.existsSync(malformedBackupDirectory), false);

      const statusResult = run(nodePath, [
        path.join(routingDir, "configure-ccswitch-route.js"),
        "--database", databasePath,
        "--settings", settingsPath,
        "--app-type", "claude-desktop",
        "--status",
      ]);
      assert.equal(statusResult.status, 0, `${statusResult.stdout}\n${statusResult.stderr}`);
      assert.match(statusResult.stdout, /claude-desktop/);
      assert.doesNotMatch(statusResult.stdout, /mac-route-test-secret/);

      const ambiguousDatabase = new DatabaseSync(databasePath);
      try {
        ambiguousDatabase.prepare(
          "INSERT INTO providers (id, app_type, settings_config, is_current) VALUES (?, ?, ?, 1)",
        ).run("provider-2", "claude", JSON.stringify({
          env: { ANTHROPIC_BASE_URL: "https://other-text.example/v1" },
        }));
      } finally {
        ambiguousDatabase.close();
      }
      const ambiguousAutoResult = run(nodePath, [
        path.join(routingDir, "configure-ccswitch-route.js"),
        "--database", databasePath,
        "--settings", settingsPath,
        "--app-type", "auto",
        "--status",
      ]);
      assert.notEqual(ambiguousAutoResult.status, 0);
      assert.match(
        `${ambiguousAutoResult.stdout}\n${ambiguousAutoResult.stderr}`,
        /pass --app-type claude or --app-type claude-desktop/,
      );

      fs.writeFileSync(settingsPath, JSON.stringify({ currentProviderClaudeDesktop: "other-provider" }), "utf8");
      const mismatchedSettingsResult = run(nodePath, [
        path.join(routingDir, "configure-ccswitch-route.js"),
        "--database", databasePath,
        "--settings", settingsPath,
        "--app-type", "claude-desktop",
        "--status",
      ]);
      assert.notEqual(mismatchedSettingsResult.status, 0);
      assert.match(
        `${mismatchedSettingsResult.stdout}\n${mismatchedSettingsResult.stderr}`,
        /does not match the database/,
      );
    } else if (!DatabaseSync) {
      console.log("macOS CC Switch route smoke test: SKIP (node:sqlite unavailable)");
    } else {
      console.log("macOS CC Switch route smoke test: SKIP (CC Switch is running; route mutation requires it to be stopped)");
    }

    const skillEnvironment = { ...process.env, HOME: home };
    for (const name of [
      "BRIDGE_ENV_FILE",
      "VISION_API_KEY",
      "VISION_BASE_URL",
      "VISION_MODEL",
    ]) {
      delete skillEnvironment[name];
    }
    const visionSkillResult = await runAsync("sh", [
      path.join(home, ".claude", "skills", "vision", "vision.sh"),
      "--url", "https://example.com/mac-skill.png", "describe this image",
    ], { env: skillEnvironment });
    assert.equal(visionSkillResult.status, 0, `${visionSkillResult.stdout}\n${visionSkillResult.stderr}`);
    assert.match(visionSkillResult.stdout, /macOS Vision Skill response/);
    assert.equal(receivedVisionAuthorization, "Bearer mac-startup-test-secret");
    assert.doesNotMatch(
      `${visionSkillResult.stdout}\n${visionSkillResult.stderr}`,
      /mac-startup-test-secret/,
    );

    bridgeProcess = spawn("sh", [path.join(bridgeDir, "start-vision-bridge.sh")], {
      env: { ...process.env, HOME: home },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let bridgeOutput = "";
    bridgeProcess.stdout.setEncoding("utf8");
    bridgeProcess.stderr.setEncoding("utf8");
    bridgeProcess.stdout.on("data", (chunk) => { bridgeOutput += chunk; });
    bridgeProcess.stderr.on("data", (chunk) => { bridgeOutput += chunk; });
    await waitForHealth(bridgePort);
    assert.equal(bridgeProcess.exitCode, null);
    assert.doesNotMatch(bridgeOutput, /mac-startup-test-secret/);
    bridgeProcess.kill("SIGTERM");
    await new Promise((resolve) => bridgeProcess.once("exit", resolve));
    bridgeProcess = null;

    const healthResult = await runAsync(nodePath, [path.join(bridgeDir, "bridge-health.js"), `http://127.0.0.1:${healthPort}/health`]);
    assert.equal(healthResult.status, 0, `${healthResult.stdout}\n${healthResult.stderr}`);
    console.log("macOS smoke test: PASS");
  } finally {
    if (bridgeProcess && bridgeProcess.exitCode === null) bridgeProcess.kill("SIGTERM");
    await close(visionServer);
    await close(authenticatedHealthServer);
    await close(healthServer);
    fs.rmSync(root, { recursive: true, force: true });
  }
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exitCode = 1;
});
