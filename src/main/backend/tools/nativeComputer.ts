import type { Computer, RunContext } from "@openai/agents";
import type { NativeComputerBridge } from "./nativeComputerBridge";
import type { GPTMouseButton } from "./computerControlLayer";

export class NativeComputer implements Computer {
  environment: "mac" = "mac";
  dimensions: [number, number] = [1440, 900];

  constructor(private readonly bridge: NativeComputerBridge) {}

  async initRun(_runContext?: RunContext): Promise<void> {
    const display = await this.bridge.getPrimaryDisplay();
    this.dimensions = [display.width, display.height];
  }

  async screenshot(): Promise<string> {
    return this.bridge.screenshot();
  }

  async click(
    x: number,
    y: number,
    button: "left" | "right" | "wheel" | "back" | "forward"
  ): Promise<void> {
    await this.bridge.click(x, y, button);
  }

  async doubleClick(
    x: number,
    y: number,
    _runContext?: RunContext,
    button: GPTMouseButton = "left"
  ): Promise<void> {
    await this.bridge.doubleClick(x, y, button);
  }

  async scroll(x: number, y: number, scrollX: number, scrollY: number): Promise<void> {
    await this.bridge.scroll(x, y, scrollX, scrollY);
  }

  async type(text: string): Promise<void> {
    await this.bridge.type(text);
  }

  async wait(_runContext?: RunContext, durationMs = 900): Promise<void> {
    const delayMs = Number.isFinite(durationMs) ? Math.max(0, Math.round(durationMs)) : 900;
    await new Promise((resolve) => setTimeout(resolve, delayMs));
  }

  async move(x: number, y: number): Promise<void> {
    await this.bridge.move(x, y);
  }

  async keypress(keys: string[]): Promise<void> {
    await this.bridge.keypress(keys);
  }

  async drag(path: [number, number][]): Promise<void> {
    await this.bridge.drag(path);
  }
}
