import { defineConfig } from "tsup";

export default defineConfig({
  entry: {
    "voice-runtime": "src/voice/runtime.ts"
  },
  format: ["iife"],
  target: "es2022",
  platform: "browser",
  outDir: "dist-voice",
  clean: true,
  splitting: false,
  sourcemap: true,
  dts: false,
  minify: false,
  outExtension() {
    return {
      js: ".js"
    };
  },
  env: {
    NODE_ENV: process.env.NODE_ENV ?? "development"
  }
});
