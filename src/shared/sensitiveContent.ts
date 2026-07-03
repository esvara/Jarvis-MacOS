/// Single source of truth for sensitive-content detection and redaction.
/// codexBridge (delegation gate) and riskPolicy (backend approvals) consume
/// these patterns with their own reasons/wording; keeping the regexes here
/// stops the two gates from drifting apart when patterns are updated.

export const sensitivePatterns = {
  credentials: /\b(password|token|api key|secret|credential)\b/i,
  payments: /\b(payment|purchase|buy|checkout|order)\b/i,
  externalSends: /\b(send|email|message|post|publish|submit)\b/i,
  massDeletion: /\bdelete\b.*\b(all|everything|entire|mass|bulk)\b/i,
  destructiveShell: /\b(rm\s+-rf|diskutil|mkfs|sudo)\b/i,
  // Broader variant used by the delegation gate, where prose like
  // "delete all my drafts" must also be caught.
  destructiveShellBroad: /\b(rm\s+-rf|diskutil|mkfs|sudo|delete all|erase)\b/i,
  sensitiveDomains: /\b(legal|financial|tax|bank|medical)\b/i
} as const;

/// Strip API keys, bearer tokens, and key=value/key: value secrets from text
/// before it is logged, summarized, or spoken.
export function redactSensitiveText(text: string): string {
  return text
    .replace(/\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b/g, "[redacted-openai-key]")
    .replace(/\bBearer\s+[A-Za-z0-9._-]{20,}\b/g, "Bearer [redacted-token]")
    .replace(/\b(JARVIS_AUTH_TOKEN|OPENAI_API_KEY)=\S+/g, "$1=[redacted]")
    .replace(/\b(api[_ -]?key|token|secret|password):\s*\S+/gi, "$1: [redacted]");
}
