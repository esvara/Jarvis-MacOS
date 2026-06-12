import { z } from "zod";
import {
  type CodexCommandRequest,
  memoryKinds,
  type MemoryForgetInput,
  type MemorySaveInput,
  type MemorySearchInput
} from "./types";
import type { CodexBridgeMode } from "./samanthaConfig";

const memoryKindSchema = z.enum(memoryKinds);

const nullableStringSchema = z.string().nullable();
const nullableStringArraySchema = z.array(z.string()).nullable();

const strictObject = <T extends Record<string, unknown>>(properties: T) => ({
  type: "object",
  properties,
  required: Object.keys(properties),
  additionalProperties: false
} as const);

export const searchMemoryToolParameters = strictObject({
  query: {
    type: "string",
    minLength: 1
  },
  kinds: {
    type: ["array", "null"],
    items: {
      type: "string",
      enum: [...memoryKinds]
    }
  },
  limit: {
    type: ["integer", "null"],
    minimum: 1,
    maximum: 25
  }
});

const searchMemoryToolInputSchema = z.object({
  query: z.string().min(1),
  kinds: z.array(memoryKindSchema).nullable(),
  limit: z.number().int().min(1).max(25).nullable()
});

export function parseSearchMemoryToolInput(input: unknown): MemorySearchInput {
  const parsed = searchMemoryToolInputSchema.parse(input);
  return {
    query: parsed.query,
    kinds: parsed.kinds ?? undefined,
    limit: parsed.limit ?? undefined
  };
}

export const saveMemoryToolParameters = strictObject({
  kind: {
    type: "string",
    enum: [...memoryKinds]
  },
  subject: {
    type: "string",
    minLength: 3
  },
  content: {
    type: "string",
    minLength: 3
  },
  confidence: {
    type: "number",
    minimum: 0,
    maximum: 1
  },
  source: {
    type: "string",
    minLength: 2
  },
  tags: {
    type: ["array", "null"],
    items: {
      type: "string"
    }
  }
});

const saveMemoryToolInputSchema = z.object({
  kind: memoryKindSchema,
  subject: z.string().min(3),
  content: z.string().min(3),
  confidence: z.number().min(0).max(1),
  source: z.string().min(2),
  tags: nullableStringArraySchema
});

export function parseSaveMemoryToolInput(input: unknown): MemorySaveInput {
  const parsed = saveMemoryToolInputSchema.parse(input);
  return {
    ...parsed,
    tags: parsed.tags ?? undefined
  };
}

export const forgetMemoryToolParameters = strictObject({
  id: {
    type: ["string", "null"]
  },
  query: {
    type: ["string", "null"]
  }
});

const forgetMemoryToolInputSchema = z.object({
  id: nullableStringSchema,
  query: nullableStringSchema
});

export function parseForgetMemoryToolInput(input: unknown): MemoryForgetInput {
  const parsed = forgetMemoryToolInputSchema.parse(input);
  return {
    id: parsed.id ?? undefined,
    query: parsed.query ?? undefined
  };
}

export const startBackendTaskToolParameters = strictObject({
  request: {
    type: "string",
    minLength: 3
  },
  activeAppHint: {
    type: ["string", "null"]
  }
});

const startBackendTaskToolInputSchema = z.object({
  request: z.string().min(3),
  activeAppHint: nullableStringSchema
});

export function parseStartBackendTaskToolInput(input: unknown): {
  request: string;
  activeAppHint?: string;
} {
  const parsed = startBackendTaskToolInputSchema.parse(input);
  return {
    request: parsed.request,
    activeAppHint: parsed.activeAppHint ?? undefined
  };
}

const codexBridgeModeSchema = z.enum(["observe", "assist", "drive"]);

export const codexCommandToolParameters = strictObject({
  intent: {
    type: "string",
    minLength: 3
  },
  command: {
    type: "string",
    minLength: 3
  },
  agent: {
    type: ["string", "null"],
    enum: ["codex", "claude", null]
  },
  modeHint: {
    type: ["string", "null"],
    enum: ["observe", "assist", "drive", null]
  },
  requireConfirmation: {
    type: ["boolean", "null"]
  }
});

const agentAppSchema = z.enum(["codex", "claude"]);

const codexCommandToolInputSchema = z.object({
  intent: z.string().min(3),
  command: z.string().min(3),
  agent: agentAppSchema.nullish(),
  modeHint: codexBridgeModeSchema.nullable(),
  requireConfirmation: z.boolean().nullable()
});

export function parseCodexCommandToolInput(input: unknown): CodexCommandRequest {
  const parsed = codexCommandToolInputSchema.parse(input);
  return {
    intent: parsed.intent,
    command: parsed.command,
    agent: parsed.agent ?? undefined,
    modeHint: (parsed.modeHint ?? undefined) as CodexBridgeMode | undefined,
    requireConfirmation: parsed.requireConfirmation ?? undefined
  };
}

export const pasteIntoAppToolParameters = strictObject({
  appName: {
    type: "string",
    minLength: 2
  },
  text: {
    type: "string",
    minLength: 1
  },
  submit: {
    type: ["boolean", "null"]
  }
});

const pasteIntoAppToolInputSchema = z.object({
  appName: z.string().min(2),
  text: z.string().min(1),
  submit: z.boolean().nullish()
});

export function parsePasteIntoAppToolInput(input: unknown): { app: string; text: string; submit: boolean } {
  const parsed = pasteIntoAppToolInputSchema.parse(input);
  return {
    app: parsed.appName,
    text: parsed.text,
    submit: parsed.submit ?? false
  };
}

export const clickInAppToolParameters = strictObject({
  appName: {
    type: "string",
    minLength: 2
  },
  label: {
    type: "string",
    minLength: 1
  }
});

const clickInAppToolInputSchema = z.object({
  appName: z.string().min(2),
  label: z.string().min(1)
});

export function parseClickInAppToolInput(input: unknown): { app: string; label: string } {
  const parsed = clickInAppToolInputSchema.parse(input);
  return { app: parsed.appName, label: parsed.label };
}

export const openFileToolParameters = strictObject({
  path: {
    type: ["string", "null"]
  },
  query: {
    type: ["string", "null"]
  },
  appName: {
    type: ["string", "null"]
  }
});

const openFileToolInputSchema = z.object({
  path: z.string().nullish(),
  query: z.string().nullish(),
  appName: z.string().nullish()
});

export function parseOpenFileToolInput(input: unknown): {
  path?: string;
  query?: string;
  appName?: string;
} {
  const parsed = openFileToolInputSchema.parse(input);
  return {
    path: parsed.path ?? undefined,
    query: parsed.query ?? undefined,
    appName: parsed.appName ?? undefined
  };
}

export const codexStatusToolParameters = strictObject({
  query: {
    type: ["string", "null"]
  },
  agent: {
    type: ["string", "null"],
    enum: ["codex", "claude", null]
  }
});

const codexStatusToolInputSchema = z.object({
  query: nullableStringSchema,
  agent: agentAppSchema.nullish()
});

export function parseCodexStatusToolInput(input: unknown): { query?: string; agent?: "codex" | "claude" } {
  const parsed = codexStatusToolInputSchema.parse(input);
  return {
    query: parsed.query ?? undefined,
    agent: parsed.agent ?? undefined
  };
}
