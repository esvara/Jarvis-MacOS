import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { APP_DISPLAY_NAME } from "./samanthaConfig";

export const APP_NAME = APP_DISPLAY_NAME;

export function resolveApplicationSupportRoot(): string {
  const baseDirectory = path.join(os.homedir(), "Library", "Application Support");
  return path.join(baseDirectory, APP_NAME);
}

export function resolveAppLogsDirectory(): string {
  const logsDirectory = path.join(resolveApplicationSupportRoot(), "logs");
  fs.mkdirSync(logsDirectory, { recursive: true });
  return logsDirectory;
}
