import { describe, expect, it } from "vitest";
import { adaptRawRunItem, getComputerCallActions } from "./rawRunItemAdapter";

describe("rawRunItemAdapter", () => {
  it("normalizes multi-action computer calls with alias fields", () => {
    const item = adaptRawRunItem({
      type: "computer_call",
      actions: [
        {
          type: "scroll",
          x: 100,
          y: 200,
          deltaX: 12,
          delta_y: -24
        },
        {
          type: "wait",
          duration_ms: 750
        },
        {
          type: "keypress",
          key: "Enter"
        }
      ]
    });

    expect(item).toEqual({
      type: "computer_call",
      actions: [
        {
          type: "scroll",
          x: 100,
          y: 200,
          scrollX: 12,
          scrollY: -24
        },
        {
          type: "wait",
          durationMs: 750
        },
        {
          type: "keypress",
          keys: ["Enter"]
        }
      ],
      raw: {
        type: "computer_call",
        actions: [
          {
            type: "scroll",
            x: 100,
            y: 200,
            deltaX: 12,
            delta_y: -24
          },
          {
            type: "wait",
            duration_ms: 750
          },
          {
            type: "keypress",
            key: "Enter"
          }
        ]
      }
    });
  });

  it("supports legacy single-action computer calls", () => {
    expect(
      getComputerCallActions({
        type: "computer_call",
        action: {
          type: "double_click",
          x: 42,
          y: 99,
          button: "right"
        }
      })
    ).toEqual([
      {
        type: "double_click",
        x: 42,
        y: 99,
        button: "right"
      }
    ]);
  });

  it("extracts screenshot data from computer call results", () => {
    expect(
      adaptRawRunItem({
        type: "computer_call_result",
        output: {
          data: "base64-image"
        }
      })
    ).toEqual({
      type: "computer_call_result",
      imageBase64: "base64-image",
      raw: {
        type: "computer_call_result",
        output: {
          data: "base64-image"
        }
      }
    });
  });
});
