import fs from "node:fs";
import path from "node:path";
import { resolveAppLogsDirectory } from "../shared/appIdentity";

const LOG_DIR = resolveAppLogsDirectory();
const LOG_FILE = path.join(LOG_DIR, "sidecar.log");
const MAX_SIZE = 2 * 1024 * 1024; // 2 MB

function rotateIfNeeded() {
  try {
    const stat = fs.statSync(LOG_FILE);
    if (stat.size > MAX_SIZE) {
      const prev = `${LOG_FILE}.prev`;
      if (fs.existsSync(prev)) {
        fs.unlinkSync(prev);
      }
      fs.renameSync(LOG_FILE, prev);
    }
  } catch {
    // file doesn't exist yet - fine
  }
}

function write(level: string, message: string, data?: unknown) {
  const ts = new Date().toISOString();
  let line = `${ts} [${level}] ${message}`;
  if (data !== undefined) {
    try {
      line += ` ${JSON.stringify(data)}`;
    } catch {
      line += " [unserializable]";
    }
  }
  line += "\n";
  try {
    fs.appendFileSync(LOG_FILE, line);
  } catch {
    // best-effort
  }
}

export const logger = {
  info: (msg: string, data?: unknown) => write("INFO", msg, data),
  warn: (msg: string, data?: unknown) => write("WARN", msg, data),
  error: (msg: string, data?: unknown) => write("ERROR", msg, data),
  path: LOG_FILE,
  rotate: rotateIfNeeded
};
