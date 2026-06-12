import { z } from "zod";
import {
  GPT_MOUSE_BUTTONS,
  type GPTMouseButton,
  type InputPoint
} from "../tools/computerControlLayer";

const mouseButtonSchema = z.enum(GPT_MOUSE_BUTTONS);
const pointSchema = z.object({
  x: z.number(),
  y: z.number()
});

const screenshotActionSchema = z.object({
  type: z.literal("screenshot")
}).passthrough();

const clickActionSchema = z.object({
  type: z.literal("click"),
  x: z.number(),
  y: z.number(),
  button: mouseButtonSchema
}).passthrough();

const doubleClickActionSchema = z.object({
  type: z.literal("double_click"),
  x: z.number(),
  y: z.number(),
  button: mouseButtonSchema.optional()
}).passthrough();

const scrollActionSchema = z.object({
  type: z.literal("scroll"),
  x: z.number(),
  y: z.number(),
  scroll_x: z.number().optional(),
  scroll_y: z.number().optional(),
  delta_x: z.number().optional(),
  deltaX: z.number().optional(),
  delta_y: z.number().optional(),
  deltaY: z.number().optional()
}).passthrough();

const typeActionSchema = z.object({
  type: z.literal("type"),
  text: z.string()
}).passthrough();

const waitActionSchema = z.object({
  type: z.literal("wait"),
  ms: z.number().optional(),
  duration_ms: z.number().optional()
}).passthrough();

const moveActionSchema = z.object({
  type: z.literal("move"),
  x: z.number(),
  y: z.number()
}).passthrough();

const keypressActionSchema = z.object({
  type: z.literal("keypress"),
  keys: z.array(z.string()).optional(),
  key: z.string().optional()
}).passthrough();

const dragActionSchema = z.object({
  type: z.literal("drag"),
  path: z.array(pointSchema)
}).passthrough();

const rawComputerActionSchema = z.discriminatedUnion("type", [
  screenshotActionSchema,
  clickActionSchema,
  doubleClickActionSchema,
  scrollActionSchema,
  typeActionSchema,
  waitActionSchema,
  moveActionSchema,
  keypressActionSchema,
  dragActionSchema
]);

export type AdaptedComputerAction =
  | {
      type: "screenshot";
    }
  | {
      type: "click";
      x: number;
      y: number;
      button: GPTMouseButton;
    }
  | {
      type: "double_click";
      x: number;
      y: number;
      button?: GPTMouseButton;
    }
  | {
      type: "scroll";
      x: number;
      y: number;
      scrollX: number;
      scrollY: number;
    }
  | {
      type: "type";
      text: string;
    }
  | {
      type: "wait";
      durationMs: number;
    }
  | {
      type: "move";
      x: number;
      y: number;
    }
  | {
      type: "keypress";
      keys: string[];
    }
  | {
      type: "drag";
      path: InputPoint[];
    };

export type AdaptedRunItem =
  | {
      type: "computer_call";
      actions: AdaptedComputerAction[];
      raw: unknown;
    }
  | {
      type: "computer_call_result";
      imageBase64: string;
      raw: unknown;
    }
  | {
      type: "shell_call";
      commands: string[];
      raw: unknown;
    }
  | {
      type: "apply_patch_call";
      operationType: string;
      path?: string;
      diff?: string;
      raw: unknown;
    }
  | {
      type: "unknown";
      rawType?: string;
      name?: string;
      raw: unknown;
    };

const computerCallSchema = z.object({
  type: z.literal("computer_call"),
  action: rawComputerActionSchema.optional(),
  actions: z.array(rawComputerActionSchema).optional()
}).passthrough();

const computerCallResultSchema = z.object({
  type: z.literal("computer_call_result"),
  output: z.object({
    data: z.string()
  }).passthrough()
}).passthrough();

const shellCallSchema = z.object({
  type: z.literal("shell_call"),
  action: z.object({
    commands: z.array(z.string())
  }).passthrough()
}).passthrough();

const applyPatchCallSchema = z.object({
  type: z.literal("apply_patch_call"),
  operation: z.object({
    type: z.string(),
    path: z.string().optional(),
    diff: z.string().optional()
  }).passthrough()
}).passthrough();

const rawNamedItemSchema = z.object({
  type: z.string().optional(),
  name: z.string().optional()
}).passthrough();

function adaptComputerAction(rawAction: z.infer<typeof rawComputerActionSchema>): AdaptedComputerAction {
  switch (rawAction.type) {
    case "screenshot":
      return { type: "screenshot" };
    case "click":
      return {
        type: "click",
        x: rawAction.x,
        y: rawAction.y,
        button: rawAction.button
      };
    case "double_click":
      return {
        type: "double_click",
        x: rawAction.x,
        y: rawAction.y,
        button: rawAction.button
      };
    case "scroll":
      return {
        type: "scroll",
        x: rawAction.x,
        y: rawAction.y,
        scrollX: rawAction.scroll_x ?? rawAction.delta_x ?? rawAction.deltaX ?? 0,
        scrollY: rawAction.scroll_y ?? rawAction.delta_y ?? rawAction.deltaY ?? 0
      };
    case "type":
      return {
        type: "type",
        text: rawAction.text
      };
    case "wait":
      return {
        type: "wait",
        durationMs: rawAction.ms ?? rawAction.duration_ms ?? 1000
      };
    case "move":
      return {
        type: "move",
        x: rawAction.x,
        y: rawAction.y
      };
    case "keypress":
      return {
        type: "keypress",
        keys: rawAction.keys?.length ? rawAction.keys : rawAction.key ? [rawAction.key] : []
      };
    case "drag":
      return {
        type: "drag",
        path: rawAction.path
      };
  }
}

export function adaptRawRunItem(rawItem: unknown): AdaptedRunItem {
  const computerCall = computerCallSchema.safeParse(rawItem);
  if (computerCall.success) {
    const actions = computerCall.data.actions
      ?? (computerCall.data.action ? [computerCall.data.action] : []);
    return {
      type: "computer_call",
      actions: actions.map(adaptComputerAction),
      raw: rawItem
    };
  }

  const computerCallResult = computerCallResultSchema.safeParse(rawItem);
  if (computerCallResult.success) {
    return {
      type: "computer_call_result",
      imageBase64: computerCallResult.data.output.data,
      raw: rawItem
    };
  }

  const shellCall = shellCallSchema.safeParse(rawItem);
  if (shellCall.success) {
    return {
      type: "shell_call",
      commands: shellCall.data.action.commands,
      raw: rawItem
    };
  }

  const applyPatchCall = applyPatchCallSchema.safeParse(rawItem);
  if (applyPatchCall.success) {
    return {
      type: "apply_patch_call",
      operationType: applyPatchCall.data.operation.type,
      path: applyPatchCall.data.operation.path,
      diff: applyPatchCall.data.operation.diff,
      raw: rawItem
    };
  }

  const namedItem = rawNamedItemSchema.safeParse(rawItem);
  if (namedItem.success) {
    return {
      type: "unknown",
      rawType: namedItem.data.type,
      name: namedItem.data.name,
      raw: rawItem
    };
  }

  return {
    type: "unknown",
    raw: rawItem
  };
}

export function getComputerCallActions(rawItem: unknown): AdaptedComputerAction[] {
  const adapted = adaptRawRunItem(rawItem);
  return adapted.type === "computer_call" ? adapted.actions : [];
}
