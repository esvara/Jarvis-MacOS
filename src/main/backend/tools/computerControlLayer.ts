export const GPT_MOUSE_BUTTONS = ["left", "right", "wheel", "back", "forward"] as const;

export type GPTMouseButton = (typeof GPT_MOUSE_BUTTONS)[number];

export interface InputPoint {
  x: number;
  y: number;
}

export type NativeInputAction =
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
      type: "move";
      x: number;
      y: number;
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
      type: "keypress";
      keys: string[];
    }
  | {
      type: "hotkey";
      combo: string;
    }
  | {
      type: "drag";
      path: InputPoint[];
    };

export type ClickInputAction = Extract<NativeInputAction, { type: "click" }>;
export type DoubleClickInputAction = Extract<NativeInputAction, { type: "double_click" }>;
export type MoveInputAction = Extract<NativeInputAction, { type: "move" }>;
export type ScrollInputAction = Extract<NativeInputAction, { type: "scroll" }>;
export type TypeInputAction = Extract<NativeInputAction, { type: "type" }>;
export type KeyInputAction = Extract<NativeInputAction, { type: "keypress" | "hotkey" }>;
export type DragInputAction = Extract<NativeInputAction, { type: "drag" }>;

function roundPoint(point: InputPoint): InputPoint {
  return {
    x: Math.round(point.x),
    y: Math.round(point.y)
  };
}

function assertSupportedMouseButton(button: string): asserts button is GPTMouseButton {
  if ((GPT_MOUSE_BUTTONS as readonly string[]).includes(button)) {
    return;
  }
  throw new Error(`Unsupported mouse button: ${button}`);
}

export function roundNativeInputAction<T extends NativeInputAction>(action: T): T {
  switch (action.type) {
    case "click":
    case "double_click":
    case "move":
      return {
        ...action,
        x: Math.round(action.x),
        y: Math.round(action.y)
      } as T;
    case "scroll":
      return {
        ...action,
        x: Math.round(action.x),
        y: Math.round(action.y)
      } as T;
    case "drag":
      return {
        ...action,
        path: action.path.map(roundPoint)
      } as T;
    case "keypress":
    case "hotkey":
    case "type":
      return action;
  }
}

export function createClickAction(x: number, y: number, button: string): ClickInputAction {
  assertSupportedMouseButton(button);
  return roundNativeInputAction({
    type: "click",
    x,
    y,
    button
  });
}

export function createDoubleClickAction(
  x: number,
  y: number,
  button?: string
): DoubleClickInputAction {
  if (button !== undefined) {
    assertSupportedMouseButton(button);
  }
  return roundNativeInputAction({
    type: "double_click",
    x,
    y,
    button
  });
}

export function createMoveAction(x: number, y: number): MoveInputAction {
  return roundNativeInputAction({
    type: "move",
    x,
    y
  });
}

export function createScrollAction(
  x: number,
  y: number,
  scrollX: number,
  scrollY: number
): ScrollInputAction {
  return roundNativeInputAction({
    type: "scroll",
    x,
    y,
    scrollX,
    scrollY
  });
}

export function createTypeAction(text: string): TypeInputAction {
  return {
    type: "type",
    text
  };
}

export function createKeyAction(keys: string[]): KeyInputAction {
  const normalizedKeys = keys.map((key) => key.trim().toLowerCase()).filter(Boolean);
  if (normalizedKeys.length === 0) {
    throw new Error("keypress requires at least one key");
  }
  if (normalizedKeys.length === 1) {
    return {
      type: "keypress",
      keys: normalizedKeys
    };
  }
  return {
    type: "hotkey",
    combo: normalizedKeys.join(",")
  };
}

export function createDragAction(path: [number, number][]): DragInputAction {
  if (path.length < 2) {
    throw new Error("drag requires at least two points");
  }
  return roundNativeInputAction({
    type: "drag",
    path: path.map(([x, y]) => ({ x, y }))
  });
}
