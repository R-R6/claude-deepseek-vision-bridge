#!/usr/bin/env node
const fs = require("node:fs");
const { DatabaseSync } = require("node:sqlite");

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
}

function main() {
  const request = JSON.parse(fs.readFileSync(0, "utf8"));
  if (!request || typeof request !== "object" ||
      typeof request.databasePath !== "string" || typeof request.operation !== "string") {
    throw new Error("Invalid CC Switch SQLite request.");
  }

  const database = new DatabaseSync(request.databasePath);
  try {
    if (request.operation === "backup") {
      if (typeof request.backupPath !== "string") throw new Error("Missing backup path.");
      const escapedBackupPath = request.backupPath.replace(/'/g, "''");
      database.exec(`VACUUM INTO '${escapedBackupPath}'`);
      return;
    }
    if (typeof request.sql !== "string") throw new Error("Missing SQL statement.");

    const statement = database.prepare(request.sql);
    if (request.operation === "scalar") {
      const rows = statement.all();
      if (rows.length !== 1 || Object.keys(rows[0]).length !== 1) {
        throw new Error("Expected exactly one scalar database result.");
      }
      process.stdout.write(`${Object.values(rows[0])[0]}\n`);
      return;
    }
    if (request.operation === "rows") {
      for (const row of statement.all()) {
        process.stdout.write(`${Object.values(row).join("|")}\n`);
      }
      return;
    }
    if (request.operation === "execute") {
      process.stdout.write(`${statement.run().changes}\n`);
      return;
    }
    throw new Error("Unsupported CC Switch SQLite operation.");
  } finally {
    database.close();
  }
}

try {
  main();
} catch (error) {
  fail(error instanceof Error ? error.message : String(error));
}
