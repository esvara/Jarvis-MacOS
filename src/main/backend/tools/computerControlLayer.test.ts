import { describe, expect, it } from "vitest";
import {
  createClickAction,
  createDoubleClickAction,
  createDragAction,
  createKeyAction
} from "./computerControlLayer";

describe("computerControlLayer", () => {
  it("preserves supported mouse buttons instead of coercing them", () => {
    expect(createClickAction(10.2, 15.9, "left")).toEqual({
      type: "click",
      x: 10,
      y: 16,
      button: "left"
    });

    expect(createClickAction(10.2, 15.9, "wheel")).toEqual({
      type: "click",
      x: 10,
      y: 16,
      button: "wheel"
    });

    expect(createClickAction(10.2, 15.9, "back")).toEqual({
      type: "click",
      x: 10,
      y: 16,
      button: "back"
    });

    expect(createClickAction(10.2, 15.9, "forward")).toEqual({
      type: "click",
      x: 10,
      y: 16,
      button: "forward"
    });
  });

  it("rejects unsupported mouse buttons explicitly", () => {
    expect(() => createClickAction(10, 15, "middle")).toThrow("Unsupported mouse button");
  });

  it("preserves explicit double-click buttons when provided", () => {
    expect(createDoubleClickAction(10.2, 15.9, "right")).toEqual({
      type: "double_click",
      x: 10,
      y: 16,
      button: "right"
    });
  });

  it("preserves the full drag polyline", () => {
    expect(createDragAction([
      [0.4, 1.6],
      [9.5, 10.4],
      [20.1, 30.8]
    ])).toEqual({
      type: "drag",
      path: [
        { x: 0, y: 2 },
        { x: 10, y: 10 },
        { x: 20, y: 31 }
      ]
    });
  });

  it("rejects drag gestures with fewer than two points", () => {
    expect(() => createDragAction([[5, 5]])).toThrow("drag requires at least two points");
  });

  it("maps multi-key presses to a hotkey combo and normalizes casing", () => {
    expect(createKeyAction(["CMD", "A"])).toEqual({
      type: "hotkey",
      combo: "cmd,a"
    });
  });

  it("keeps single-key presses as keypress actions", () => {
    expect(createKeyAction([" Shift "])).toEqual({
      type: "keypress",
      keys: ["shift"]
    });
  });
});
