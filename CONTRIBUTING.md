# Contributing

## Prerequisites

- macOS 14 or newer
- Node.js 20 or 22
- Swift 6 / Xcode Command Line Tools
- An OpenAI API key for manual testing

## Local Setup

```bash
npm install
npm run dev
```

If you only need the backend and native tests:

```bash
npm run ci
```

## Development Workflow

1. Make the smallest coherent change you can.
2. Keep the native app, sidecar, and voice runtime behavior aligned.
3. Add or update tests for parser, adapter, validation, and regression behavior.
4. Run the full validation command before asking for review.

## Validation Checklist

```bash
npm run ci
npm run build:native
```

If your change touches permissions, hotkeys, focus behavior, or computer control, also do a manual macOS smoke test.

## Style Expectations

- Prefer explicit types at the boundaries between the voice runtime, sidecar, agent runtime, and native input layer.
- Keep the transport, parsing, and execution layers separated.
- Avoid silent coercions for unsupported computer actions or key names.
- Do not introduce new generated assets or local build output into the repository.

## Pull Requests

- Explain the user-visible change and the architecture impact.
- Call out any macOS-specific manual verification you performed.
- Note any permissions or signing assumptions required to reproduce the behavior.
