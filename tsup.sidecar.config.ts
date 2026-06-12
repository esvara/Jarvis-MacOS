import { defineConfig } from "tsup";

export default defineConfig({
  entry: {
    sidecar: "src/sidecar/server.ts"
  },
  format: ["cjs"],
  target: "node20",
  platform: "node",
  outDir: "dist-sidecar",
  clean: true,
  splitting: false,
  sourcemap: true,
  dts: false,
  outExtension() {
    return {
      js: ".cjs"
    };
  },
  env: {
    NODE_ENV: process.env.NODE_ENV ?? "development"
  }
});
