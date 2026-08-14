#!/usr/bin/env node
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");

function listen(server) {
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server.address().port)));
}

function close(server) {
  return new Promise((resolve) => server.close(resolve));
}

function runPowerShell(args) {
  return new Promise((resolve, reject) => {
    const child = spawn("powershell.exe", [
      "-NoLogo",
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      ...args,
    ], { windowsHide: true });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", (status) => resolve({ status, stdout, stderr }));
  });
}

function writeFakeSqlite(fakePath) {
  fs.writeFileSync(fakePath, String.raw`
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Remaining)

$databasePath = $Remaining[$Remaining.Count - 2]
$sql = $Remaining[$Remaining.Count - 1]
$statePath = "$databasePath.route"
if ($sql -match "^\.backup '(.+)'$") {
    Copy-Item -LiteralPath $databasePath -Destination $matches[1] -Force
    exit 0
}
if ($sql -match "SELECT DISTINCT id FROM providers") {
    Write-Output "provider-1"
    exit 0
}
if ($sql -match "SELECT app_type FROM providers") {
    Write-Output "claude"
    exit 0
}
if ($sql -match "SELECT CASE") {
    Write-Output "1"
    exit 0
}
if ($sql -match "UPDATE providers") {
    $route = [regex]::Match($sql, "http://[^']+").Value
    Set-Content -LiteralPath $statePath -Value $route -Encoding ASCII
    Write-Output "1"
    exit 0
}
if ($sql -match "SELECT json_extract") {
    Get-Content -Raw -Encoding ASCII -LiteralPath $statePath
    exit 0
}
Write-Error "unexpected mock sqlite command: $sql"
exit 1
`, "utf8");
}

function getDatabaseSync() {
  try {
    return require("node:sqlite").DatabaseSync;
  } catch {
    return null;
  }
}

function createRouteDatabase(databasePath) {
  const DatabaseSync = getDatabaseSync();
  if (!DatabaseSync) return false;
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
    database.prepare(`
      INSERT INTO providers (id, app_type, settings_config, is_current)
      VALUES (?, ?, ?, ?)
    `).run(
      "provider-1",
      "claude",
      JSON.stringify({
        env: {
          ANTHROPIC_BASE_URL: "https://text.example/v1",
          ANTHROPIC_AUTH_TOKEN: "route-test-secret",
        },
      }),
      1,
    );
    database.prepare(`
      INSERT INTO providers (id, app_type, settings_config, is_current)
      VALUES (?, ?, ?, ?)
    `).run(
      "provider-1",
      "claude-desktop",
      JSON.stringify({
        env: {
          ANTHROPIC_BASE_URL: "https://text.example/v1",
          ANTHROPIC_AUTH_TOKEN: "route-test-secret",
        },
      }),
      1,
    );
    return true;
  } finally {
    database.close();
  }
}

function readRoute(databasePath, appType = "claude") {
  const database = new (getDatabaseSync())(databasePath);
  try {
    return database.prepare(`
      SELECT json_extract(settings_config, '$.env.ANTHROPIC_BASE_URL') AS route
      FROM providers WHERE id = 'provider-1' AND app_type = ?
    `).get(appType).route;
  } finally {
    database.close();
  }
}

async function main() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "vision-bridge-route-"));
  const ccSwitchDirectory = path.join(root, ".cc-switch");
  const backupDirectory = path.join(root, "backup");
  const databasePath = path.join(ccSwitchDirectory, "cc-switch.db");
  const settingsPath = path.join(ccSwitchDirectory, "settings.json");
  const fakeSqlitePath = path.join(root, "sqlite3.ps1");
  const routeScript = path.join(__dirname, "..", "src", "configure-ccswitch-route.ps1");
  const health = http.createServer((request, response) => {
    if (request.url === "/health") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ ok: true, service: "vision-bridge" }));
      return;
    }
    response.writeHead(404);
    response.end();
  });

  try {
    fs.mkdirSync(ccSwitchDirectory, { recursive: true });
    const useBuiltInSqlite = createRouteDatabase(databasePath);
    if (!useBuiltInSqlite) {
      fs.writeFileSync(databasePath, "fake sqlite database", "utf8");
      fs.writeFileSync(`${databasePath}.route`, "https://text.example/v1", "ascii");
    }
    fs.writeFileSync(settingsPath, JSON.stringify({
      currentProviderClaudeDesktop: "provider-1",
    }), "utf8");
    if (!useBuiltInSqlite) writeFakeSqlite(fakeSqlitePath);
    const bridgePort = await listen(health);

    const routeArgs = [
      "-File",
      routeScript,
      "-CCSwitchDirectory",
      ccSwitchDirectory,
      "-BridgePort",
      String(bridgePort),
      "-BackupDirectory",
      backupDirectory,
      "-CCSwitchProcessName",
      "cc-switch-route-test",
      "-SkipCCSwitchRestart",
    ];
    if (!useBuiltInSqlite) routeArgs.push("-SQLitePath", fakeSqlitePath);
    const result = await runPowerShell(routeArgs);
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.match(result.stdout, /now targets the healthy Vision Bridge/i);
    const expectedRoute = `http://127.0.0.1:${bridgePort}`;
    assert.equal(
      useBuiltInSqlite ? readRoute(databasePath) : fs.readFileSync(`${databasePath}.route`, "ascii").trim(),
      expectedRoute,
    );
    if (useBuiltInSqlite) {
      assert.equal(readRoute(databasePath, "claude-desktop"), expectedRoute);
    }
    assert.equal(fs.existsSync(path.join(backupDirectory, "cc-switch.db")), true);
    if (useBuiltInSqlite) {
      assert.equal(readRoute(path.join(backupDirectory, "cc-switch.db")), "https://text.example/v1");
      assert.equal(readRoute(path.join(backupDirectory, "cc-switch.db"), "claude-desktop"), "https://text.example/v1");
    }
    assert.doesNotMatch(`${result.stdout}\n${result.stderr}`, /ANTHROPIC_AUTH_TOKEN|secret/i);

    const alreadyConfiguredArgs = [
      "-File", routeScript,
      "-CCSwitchDirectory", ccSwitchDirectory,
      "-BridgePort",
      String(bridgePort),
      "-BackupDirectory",
      path.join(root, "unused-backup"),
      "-CCSwitchProcessName",
      "cc-switch-route-test",
      "-SkipCCSwitchRestart",
    ];
    if (!useBuiltInSqlite) alreadyConfiguredArgs.push("-SQLitePath", fakeSqlitePath);
    const alreadyConfigured = await runPowerShell(alreadyConfiguredArgs);
    assert.equal(alreadyConfigured.status, 0, `${alreadyConfigured.stdout}\n${alreadyConfigured.stderr}`);
    assert.match(alreadyConfigured.stdout, /already targets/i);
    assert.equal(fs.existsSync(path.join(root, "unused-backup")), false);
    console.log("CC Switch route smoke test: PASS");
  } finally {
    await close(health);
    fs.rmSync(root, { recursive: true, force: true });
  }
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exitCode = 1;
});
