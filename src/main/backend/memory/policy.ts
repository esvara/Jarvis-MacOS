import type {
  MemoryPolicyResult,
  MemorySaveInput
} from "../../../shared/types";

const blockedPatterns = [
  /\b(password|passcode|otp|2fa|two-factor|one-time code)\b/i,
  /\b(api[-_\s]?key|secret|token|bearer)\b/i,
  /\bcredit card|ssn|social security|bank account\b/i,
  /\bclipboard\b/i,
  /\bscreenshot\b/i,
  /\bprivate message|dm\b/i
];

const volatilePatterns = [
  /\btoday\b/i,
  /\btomorrow\b/i,
  /\bthis (session|task|conversation)\b/i,
  /\bfor now\b/i,
  /\bcurrently\b/i,
  /\btemporary\b/i,
  /\buntil later\b/i
];

function normalizeTags(input: MemorySaveInput): string[] {
  const tags = new Set<string>();
  if (input.tags) {
    for (const tag of input.tags) {
      const normalized = tag.trim().toLowerCase();
      if (normalized) {
        tags.add(normalized);
      }
    }
  }
  tags.add(input.kind);
  return [...tags];
}

function looksLikeBulkContent(input: MemorySaveInput): boolean {
  return input.content.length > 500 || input.content.split("\n").length > 8;
}

export function evaluateMemoryWrite(
  input: MemorySaveInput
): MemoryPolicyResult {
  const haystack = `${input.subject}\n${input.content}`.trim();

  for (const pattern of blockedPatterns) {
    if (pattern.test(haystack)) {
      return {
        decision: "block",
        reason:
          "This memory looks sensitive or captures raw private content, so it was blocked.",
        normalizedTags: normalizeTags(input)
      };
    }
  }

  if (looksLikeBulkContent(input)) {
    return {
      decision: "block",
      reason:
        "This memory is too large and looks like a raw dump instead of a durable fact.",
      normalizedTags: normalizeTags(input)
    };
  }

  for (const pattern of volatilePatterns) {
    if (pattern.test(haystack)) {
      return {
        decision: "approval_required",
        reason:
          "This memory may be temporary or tied to the current moment, so it needs approval.",
        normalizedTags: normalizeTags(input)
      };
    }
  }

  if (input.confidence < 0.65) {
    return {
      decision: "approval_required",
      reason:
        "This memory has low confidence and needs approval before it becomes durable.",
      normalizedTags: normalizeTags(input)
    };
  }

  return {
    decision: "allow",
    reason: "This looks like a stable durable preference or environment fact.",
    normalizedTags: normalizeTags(input)
  };
}
