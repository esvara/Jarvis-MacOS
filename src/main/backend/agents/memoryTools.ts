import { tool } from "@openai/agents";
import {
  forgetMemoryToolParameters,
  parseForgetMemoryToolInput,
  parseSaveMemoryToolInput,
  parseSearchMemoryToolInput,
  saveMemoryToolParameters,
  searchMemoryToolParameters
} from "../../../shared/toolSchemas";
import type { MemoryStore } from "../memory/memoryStore";
import { evaluateMemoryWrite } from "../memory/policy";

export function buildMemoryTools(memoryStore: MemoryStore) {
  return {
    searchMemory: tool({
      name: "search_memory",
      description:
        "Look up durable memories like preferences, app aliases, workflow defaults, or environment facts.",
      parameters: searchMemoryToolParameters,
      execute: async (input) => {
        const memories = memoryStore.search(parseSearchMemoryToolInput(input));
        return {
          count: memories.length,
          memories
        };
      }
    }),
    saveMemory: tool({
      name: "save_memory",
      description:
        "Persist a stable preference, alias, workflow default, environment fact, or safe macro into durable memory. Never use this for secrets or raw captured content.",
      parameters: saveMemoryToolParameters,
      needsApproval: async (_runContext, input) => {
        const policy = evaluateMemoryWrite(parseSaveMemoryToolInput(input));
        return policy.decision === "approval_required";
      },
      execute: async (input) => {
        const normalizedInput = parseSaveMemoryToolInput(input);
        const policy = evaluateMemoryWrite(normalizedInput);
        if (policy.decision === "block") {
          return {
            status: "blocked",
            reason: policy.reason
          };
        }

        const record = memoryStore.save(
          { ...normalizedInput, tags: policy.normalizedTags },
          policy.reason
        );
        return {
          status: policy.decision === "approval_required" ? "saved_after_approval" : "saved",
          reason: policy.reason,
          memory: record
        };
      }
    }),
    forgetMemory: tool({
      name: "forget_memory",
      description:
        "Delete a durable memory by id or query when the user asks to forget or correct something.",
      parameters: forgetMemoryToolParameters,
      needsApproval: true,
      execute: async (input) => {
        const deleted = memoryStore.forget(parseForgetMemoryToolInput(input), "tool_forget");
        return {
          deletedCount: deleted.length,
          deleted
        };
      }
    })
  };
}
