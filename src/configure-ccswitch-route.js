#!/usr/bin/env node
/** Safely point the active CC Switch Claude provider at a healthy Vision Bridge. */
const fs = require("node:fs");
const http = require("node:http");
const https = require("node:https");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { isLoopbackHostname } = require("./vision-client");

const EXPECTED_BRIDGE_VERSION = "0.2.1";

function fail(message, exitCode = 1) {
  process.stderr.write(`${message}\n`);
  process.exitCode = exitCode;
}

function parseArgs(argv) {
  const options = {
    ccSwitchDirectory: path.join(os.homedir(), ".cc-switch"),
    appType: "auto",
    bridgeHost: "127.0.0.1",
    bridgePort: 15720,
    bridgeEnvFile: path.join(os.homedir(), ".claude", "bridge", "bridge.env"),
    healthTimeoutMs: 3000,
    force: false,
    status: false,
  };
  const valueOptions = new Map([
    ["--cc-switch-directory", "ccSwitchDirectory"],
    ["--database", "databasePath"],
    ["--settings", "settingsPath"],
    ["--backup-directory", "backupDirectory"],
    ["--app-type", "appType"],
    ["--bridge-host", "bridgeHost"],
    ["--bridge-port", "bridgePort"],
    ["--bridge-env-file", "bridgeEnvFile"],
    ["--health-timeout-ms", "healthTimeoutMs"],
  ]);
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--help") {
      process.stdout.write(
        "Usage: configure-ccswitch-route.js [--status] "
        + "[--app-type auto|claude|claude-desktop] [--bridge-port PORT] [--bridge-env-file PATH]\n",
      );
      process.exit(0);
    }
    if (argument === "--force") {
      options.force = true;
      continue;
    }
    if (argument === "--status") {
      options.status = true;
      continue;
    }
    const optionName = valueOptions.get(argument);
    if (!optionName || index + 1 >= argv.length) {
      throw new Error(`unknown or incomplete option: ${argument}`);
    }
    options[optionName] = argv[++index];
  }
  if (!options.databasePath) {
    options.databasePath = path.join(options.ccSwitchDirectory, "cc-switch.db");
  }
  if (!options.settingsPath) {
    options.settingsPath = path.join(options.ccSwitchDirectory, "settings.json");
  }
  if (!options.backupDirectory) {
    const stamp = new Date().toISOString().replace(/[-:TZ.]/g, "").slice(0, 14);
    options.backupDirectory = path.join(
      options.ccSwitchDirectory,
      "backups",
      `vision-bridge-${stamp}-${process.pid}`,
    );
  }
  options.bridgePort = parsePositiveInteger(options.bridgePort, "--bridge-port", 1, 65535);
  options.healthTimeoutMs = parsePositiveInteger(options.healthTimeoutMs, "--health-timeout-ms", 250, 30000);
  if (!isLoopbackHostname(options.bridgeHost)) {
    throw new Error("--bridge-host must be a loopback address");
  }
  if (!["auto", "claude", "claude-desktop"].includes(options.appType)) {
    throw new Error("--app-type must be auto, claude, or claude-desktop");
  }
  return options;
}

function parsePositiveInteger(value, name, minimum, maximum) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < minimum || parsed > maximum) {
    throw new Error(`${name} must be an integer between ${minimum} and ${maximum}`);
  }
  return parsed;
}

function loadDatabase(DatabaseSync, databasePath, readOnly = false) {
  if (!fs.existsSync(databasePath)) {
    throw new Error(`CC Switch database was not found: ${databasePath}`);
  }
  return readOnly
    ? new DatabaseSync(databasePath, { readOnly: true })
    : new DatabaseSync(databasePath);
}

function assertDatabaseIsNotInUse(databasePath) {
  if (process.platform !== "darwin") return;
  if (!fs.existsSync(databasePath)) return;
  const result = spawnSync("/usr/sbin/lsof", ["-n", path.resolve(databasePath)], {
    encoding: "utf8",
    windowsHide: true,
  });
  if (result.error || (result.status !== 0 && result.status !== 1)) {
    throw new Error("could not verify that the CC Switch database is closed");
  }
  if (result.status === 0 && result.stdout.trim()) {
    throw new Error("CC Switch database is in use; quit CC Switch before changing its route");
  }
}

function loadSettings(settingsPath) {
  if (!fs.existsSync(settingsPath)) return {};
  try {
    return JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  } catch (error) {
    throw new Error(`CC Switch settings are not valid JSON: ${error.message}`);
  }
}

function currentProviderRows(database, appType) {
  const predicate = appType === "auto"
    ? "app_type IN ('claude', 'claude-desktop')"
    : "app_type = ?";
  const statement = database.prepare(`
    SELECT id, app_type
    FROM providers
    WHERE ${predicate} AND is_current = 1
    ORDER BY app_type, id
  `);
  return appType === "auto" ? statement.all() : statement.all(appType);
}

function settingsCurrentId(settings, appType) {
  if (appType === "claude") return settings.currentProviderClaude;
  if (appType === "claude-desktop") return settings.currentProviderClaudeDesktop;
  return null;
}

function chooseProvider(rows, settings, appType) {
  if (rows.length === 0) {
    throw new Error(`no current CC Switch provider found for ${appType}`);
  }
  if (rows.length !== 1) {
    if (appType === "auto") {
      throw new Error(
        "multiple current Claude providers were found; pass --app-type claude or --app-type claude-desktop",
      );
    }
    throw new Error(`expected exactly one current ${appType} provider, found ${rows.length}`);
  }

  const row = rows[0];
  const settingsId = settingsCurrentId(settings, row.app_type);
  if (settingsId !== undefined && settingsId !== null && settingsId !== "" && settingsId !== row.id) {
    throw new Error(`CC Switch settings current ${row.app_type} provider does not match the database`);
  }
  return row;
}

function safeUrl(value) {
  try {
    const url = new URL(value);
    return `${url.protocol}//${url.host}`;
  } catch {
    return "[invalid-url]";
  }
}

function bridgeUrl(options) {
  const host = options.bridgeHost.includes(":") && !options.bridgeHost.startsWith("[")
    ? `[${options.bridgeHost}]`
    : options.bridgeHost;
  return `http://${host}:${options.bridgePort}`;
}

function readProviderRoute(database, row) {
  const validity = database.prepare(`
    SELECT json_valid(settings_config) AS is_valid
    FROM providers
    WHERE id = ? AND app_type = ?
  `).get(row.id, row.app_type);
  if (!validity || validity.is_valid !== 1) {
    throw new Error(`current ${row.app_type} provider settings are not valid JSON`);
  }

  const shape = database.prepare(`
    SELECT
      json_type(settings_config, '$.env') AS env_type,
      json_type(settings_config, '$.env.ANTHROPIC_BASE_URL') AS route_type,
      json_extract(settings_config, '$.env.ANTHROPIC_BASE_URL') AS route
    FROM providers
    WHERE id = ? AND app_type = ?
  `).get(row.id, row.app_type);
  if (!shape || shape.env_type !== "object" || shape.route_type !== "text") {
    throw new Error(
      `current ${row.app_type} provider does not have a supported env.ANTHROPIC_BASE_URL field`,
    );
  }
  return shape.route;
}

function readBridgeAuthToken(bridgeEnvFile) {
  if (Object.prototype.hasOwnProperty.call(process.env, "BRIDGE_AUTH_TOKEN")) {
    return process.env.BRIDGE_AUTH_TOKEN || "";
  }
  if (!fs.existsSync(bridgeEnvFile)) return "";

  const fileInfo = fs.lstatSync(bridgeEnvFile);
  if (!fileInfo.isFile() || fileInfo.isSymbolicLink()) {
    throw new Error(`bridge environment file must be a regular file: ${bridgeEnvFile}`);
  }
  if ((fileInfo.mode & 0o777) !== 0o600) {
    throw new Error(`bridge environment file must have 600 permissions: ${bridgeEnvFile}`);
  }

  for (const rawLine of fs.readFileSync(bridgeEnvFile, "utf8").split("\n")) {
    const line = rawLine.endsWith("\r") ? rawLine.slice(0, -1) : rawLine;
    const match = line.match(/^[ \t]*(?:export[ \t]+)?BRIDGE_AUTH_TOKEN=(.*)$/);
    if (!match) continue;
    const value = match[1];
    if (value.length >= 2
        && ((value.startsWith('"') && value.endsWith('"'))
          || (value.startsWith("'") && value.endsWith("'")))) {
      return value.slice(1, -1);
    }
    return value;
  }
  return "";
}

function checkBridgeHealth(options, bridgeAuthToken) {
  const url = new URL(`${bridgeUrl(options)}/health`);
  const transport = url.protocol === "https:" ? https : http;
  const headers = {};
  if (bridgeAuthToken) headers["x-bridge-token"] = bridgeAuthToken;
  return new Promise((resolve, reject) => {
    const request = transport.get(url, { headers }, (response) => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => { body += chunk; });
      response.on("error", reject);
      response.on("end", () => {
        if (response.statusCode !== 200) {
          reject(new Error(`Vision Bridge health returned HTTP ${response.statusCode}`));
          return;
        }
        let payload;
        try {
          payload = JSON.parse(body);
        } catch {
          reject(new Error("Vision Bridge health returned invalid JSON"));
          return;
        }
        if (payload?.ok !== true
            || payload?.service !== "vision-bridge"
            || payload?.version !== EXPECTED_BRIDGE_VERSION) {
          reject(new Error(`Vision Bridge health is not managed version ${EXPECTED_BRIDGE_VERSION}`));
          return;
        }
        resolve();
      });
    });
    request.setTimeout(options.healthTimeoutMs, () => request.destroy(new Error("Vision Bridge health timed out")));
    request.on("error", reject);
  });
}

function loadSqlite() {
  try {
    return require("node:sqlite").DatabaseSync;
  } catch {
    throw new Error("Node.js with node:sqlite is required for automatic CC Switch routing (use Node.js 22.5+ or configure the route in CC Switch)");
  }
}

function backupDatabase(database, backupPath) {
  const escapedBackupPath = backupPath.replace(/'/g, "''");
  database.exec(`VACUUM INTO '${escapedBackupPath}'`);
}

function reportStatus(database, row) {
  const route = readProviderRoute(database, row);
  process.stdout.write(
    `CC Switch active app type: ${row.app_type}; current route: ${route ? safeUrl(route) : "[missing]"}\n`,
  );
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const DatabaseSync = loadSqlite();
  const settings = loadSettings(options.settingsPath);

  // Read the current route before checking for a write lock. This makes a
  // repeated install a harmless no-op while CC Switch is still running.
  const readDatabase = loadDatabase(DatabaseSync, options.databasePath, true);
  let row;
  let target;
  let currentRoute;
  try {
    row = chooseProvider(currentProviderRows(readDatabase, options.appType), settings, options.appType);
    if (options.status) {
      reportStatus(readDatabase, row);
      return;
    }
    target = bridgeUrl(options);
    currentRoute = readProviderRoute(readDatabase, row);
  } finally {
    readDatabase.close();
  }

  const bridgeAuthToken = readBridgeAuthToken(options.bridgeEnvFile);
  await checkBridgeHealth(options, bridgeAuthToken);
  if (currentRoute === target && !options.force) {
    process.stdout.write(`CC Switch ${row.app_type} route already targets ${target}.\n`);
    return;
  }

  assertDatabaseIsNotInUse(options.databasePath);
  const database = loadDatabase(DatabaseSync, options.databasePath);
  try {
    // Re-read after the lock check so a concurrent provider change cannot be
    // overwritten based on the earlier read-only snapshot.
    const writableRow = chooseProvider(
      currentProviderRows(database, options.appType),
      settings,
      options.appType,
    );
    const writableRoute = readProviderRoute(database, writableRow);
    if (writableRoute === target && !options.force) {
      process.stdout.write(`CC Switch ${writableRow.app_type} route already targets ${target}.\n`);
      return;
    }

    fs.mkdirSync(options.backupDirectory, { recursive: true, mode: 0o700 });
    const backupDirectoryInfo = fs.lstatSync(options.backupDirectory);
    if (!backupDirectoryInfo.isDirectory() || backupDirectoryInfo.isSymbolicLink()) {
      throw new Error(`CC Switch backup directory must be a regular directory: ${options.backupDirectory}`);
    }
    fs.chmodSync(options.backupDirectory, 0o700);
    const backupPath = path.join(options.backupDirectory, "cc-switch.db");
    backupDatabase(database, backupPath);
    fs.chmodSync(backupPath, 0o600);

    database.exec("BEGIN IMMEDIATE");
    try {
      const result = database.prepare(
        "UPDATE providers SET settings_config = json_set(settings_config, '$.env.ANTHROPIC_BASE_URL', ?) WHERE id = ? AND app_type = ?",
      ).run(target, writableRow.id, writableRow.app_type);
      if (result.changes !== 1) throw new Error("CC Switch provider route update affected an unexpected number of rows");
      if (readProviderRoute(database, writableRow) !== target) {
        throw new Error("CC Switch provider route verification failed");
      }
      database.exec("COMMIT");
    } catch (error) {
      try { database.exec("ROLLBACK"); } catch {}
      throw error;
    }
    process.stdout.write(
      `CC Switch ${writableRow.app_type} route now targets healthy Vision Bridge at ${target}. Backup: ${backupPath}\n`,
    );
  } finally {
    database.close();
  }
}

main().catch((error) => fail(error instanceof Error ? error.message : String(error)));
