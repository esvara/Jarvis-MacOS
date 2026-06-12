import fs from "node:fs/promises";
import path from "node:path";
import { applyDiff } from "@openai/agents";
import type {
  ApplyPatchOperation,
  ApplyPatchResult,
  Editor
} from "@openai/agents";

function looksBinary(buffer: Buffer): boolean {
  return buffer.includes(0);
}

function isProtectedSystemPath(targetPath: string): boolean {
  const blockedRoots = ["/System", "/Library", "/bin", "/sbin", "/usr/bin"];
  return blockedRoots.some((root) => targetPath === root || targetPath.startsWith(`${root}/`));
}

export class HostEditor implements Editor {
  constructor(private readonly workingDirectory = process.cwd()) {}

  async createFile(
    operation: Extract<ApplyPatchOperation, { type: "create_file" }>
  ): Promise<ApplyPatchResult> {
    const target = this.resolveTarget(operation.path);
    await fs.mkdir(path.dirname(target), { recursive: true });
    const content = applyDiff("", operation.diff, "create");
    await fs.writeFile(target, content, "utf8");
    return { status: "completed", output: `Created ${target}` };
  }

  async updateFile(
    operation: Extract<ApplyPatchOperation, { type: "update_file" }>
  ): Promise<ApplyPatchResult> {
    const target = this.resolveTarget(operation.path);
    const current = await fs.readFile(target);
    if (looksBinary(current)) {
      throw new Error(`Refusing to patch binary file: ${target}`);
    }
    const patched = applyDiff(current.toString("utf8"), operation.diff);
    await fs.writeFile(target, patched, "utf8");
    return { status: "completed", output: `Updated ${target}` };
  }

  async deleteFile(
    operation: Extract<ApplyPatchOperation, { type: "delete_file" }>
  ): Promise<ApplyPatchResult> {
    const target = this.resolveTarget(operation.path);
    await fs.rm(target, { force: true });
    return { status: "completed", output: `Deleted ${target}` };
  }

  private resolveTarget(inputPath: string): string {
    const target = path.isAbsolute(inputPath)
      ? path.normalize(inputPath)
      : path.resolve(this.workingDirectory, inputPath);

    if (isProtectedSystemPath(target)) {
      throw new Error(`Refusing to edit protected system path: ${target}`);
    }

    return target;
  }
}
