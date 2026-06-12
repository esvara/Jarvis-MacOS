export type RiskLevel = "allow" | "approval_required" | "blocked";

export interface RiskDecision {
  level: RiskLevel;
  reason: string;
}

const blockedShellMatchers = [
  { pattern: /\brm\s+-rf\s+\/(\s|$)/, reason: "Deleting the root filesystem is blocked." },
  { pattern: /\brm\s+-rf\s+(~|\$HOME)(\s|\/|$)/, reason: "Mass deletion of the home directory is blocked." },
  { pattern: /\brm\s+-rf\s+\/Users\/[^/\s]+(\s|\/?$)/, reason: "Mass deletion of a user directory is blocked." },
  { pattern: /\bsudo\s+rm\s+-rf\b/i, reason: "Privileged recursive deletion is blocked." },
  { pattern: /\bmkfs(\.| )/i, reason: "Formatting disks is blocked." },
  { pattern: /\bdiskutil\s+(erase|partition|apfs\s+delete)/i, reason: "Destructive disk operations are blocked." },
  { pattern: /\bshutdown\b/i, reason: "Shutting down the machine is blocked." },
  { pattern: /\breboot\b/i, reason: "Rebooting the machine is blocked." },
  { pattern: /\bhalt\b/i, reason: "Halting the machine is blocked." },
  { pattern: /\blaunchctl\s+reboot\b/i, reason: "System reboot commands are blocked." },
  { pattern: /\bsecurity\s+find-(generic|internet)-password\b.*\s-w(\s|$)/i, reason: "Printing stored passwords is blocked." }
];

const approvalMatchers = [
  { pattern: /\b(payment|purchase|buy|checkout|order)\b/i, reason: "Payments and purchases need explicit user approval." },
  { pattern: /\b(password|token|api key|secret|credential)\b/i, reason: "Credentials and secrets need explicit user approval." },
  { pattern: /\b(send|email|message|post|publish|submit)\b/i, reason: "External sends or submissions need explicit user approval." },
  { pattern: /\bdelete\b.*\b(all|everything|entire|mass|bulk)\b/i, reason: "Mass deletion needs explicit user approval." },
  { pattern: /\b(rm\s+-rf|diskutil|mkfs|sudo)\b/i, reason: "Destructive or privileged shell actions need explicit user approval." },
  { pattern: /\b(legal|financial|tax|bank|medical)\b/i, reason: "Highly sensitive domains need explicit user approval." }
];

export function findHardBlockedShellReason(command: string): string | undefined {
  return blockedShellMatchers.find((entry) => entry.pattern.test(command))?.reason;
}

export function classifyTaskRisk(text: string): RiskDecision {
  const blockedShellReason = findHardBlockedShellReason(text);
  if (blockedShellReason) {
    return {
      level: "blocked",
      reason: blockedShellReason
    };
  }

  const approvalReason = approvalMatchers.find((entry) => entry.pattern.test(text))?.reason;
  if (approvalReason) {
    return {
      level: "approval_required",
      reason: approvalReason
    };
  }

  return {
    level: "allow",
    reason: "Ordinary local action."
  };
}

export const riskPolicyInstructions = `
Risk policy:
- Allowed without extra approval: observing the screen, opening local apps, navigating ordinary pages, typing ordinary non-secret text, editing workspace files, running non-destructive shell commands, and local research.
- Require explicit user approval before credentials/tokens, payments, purchases, external sends/submissions, mass deletion, destructive shell commands, system-level changes, or highly sensitive legal/financial/medical data.
- Hard blocked: root/home mass deletion, destructive disk formatting/erasing, reboot/shutdown, privileged recursive deletion, and commands that print stored passwords.
- Never read secrets aloud, write secrets to logs, or claim success without tool evidence.
`.trim();
