import { describe, expect, it } from "vitest";
import { findHardBlockedShellReason } from "../agents/riskPolicy";

describe("findHardBlockedShellReason", () => {
  it("blocks destructive erase commands", () => {
    expect(findHardBlockedShellReason("rm -rf /")).toBeTruthy();
    expect(findHardBlockedShellReason("diskutil eraseDisk APFS TEST disk3")).toBeTruthy();
    expect(findHardBlockedShellReason("rm -rf ~")).toBeTruthy();
    expect(findHardBlockedShellReason("security find-generic-password -s openai -w")).toBeTruthy();
  });

  it("allows ordinary inspection commands", () => {
    expect(findHardBlockedShellReason("pwd")).toBeUndefined();
    expect(findHardBlockedShellReason("ls -la ~/Desktop")).toBeUndefined();
  });
});
