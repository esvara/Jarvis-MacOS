import {
  Agent,
  MCPServerStdio,
  type Tool,
  applyPatchTool,
  computerTool,
  fileSearchTool,
  imageGenerationTool,
  shellTool,
  webSearchTool
} from "@openai/agents";
import { APP_DISPLAY_NAME, PLANNING_MODEL } from "../../../shared/samanthaConfig";
import type { BackendTaskEvent, SettingsData } from "../../../shared/types";
import type { MemoryStore } from "../memory/memoryStore";
import { HostEditor } from "../tools/hostEditor";
import { HostShell } from "../tools/hostShell";
import { NativeComputerBridge } from "../tools/nativeComputerBridge";
import { NativeComputer } from "../tools/nativeComputer";
import { streamEventToBackendEvent } from "./eventMapper";
import { buildMemoryTools } from "./memoryTools";
import { buildOpenClawTool } from "./openClawTool";
import { riskPolicyInstructions } from "./riskPolicy";

export interface AgentFactoryContext {
  memoryStore: MemoryStore;
  settings: SettingsData;
  workingDirectory: string;
  onEvent: (event: BackendTaskEvent) => void;
  taskId: string;
}

export interface BuiltAgents {
  operatorSupervisor: Agent;
  close: () => Promise<void>;
}

const sharedBridge = new NativeComputerBridge();

async function connectConfiguredMcpServers(settings: SettingsData) {
  const servers = settings.toolRegistry.mcpServers
    .filter((server) => server.enabled)
    .map(
      (server) =>
        new MCPServerStdio({
          name: server.label,
          fullCommand: server.fullCommand,
          cwd: server.cwd
        })
    );

  for (const server of servers) {
    await server.connect();
  }

  return servers;
}

export async function buildAgents(context: AgentFactoryContext): Promise<BuiltAgents> {
  const { settings } = context;
  const { toolRegistry } = settings;
  const memoryTools = buildMemoryTools(context.memoryStore);
  const mcpServers = await connectConfiguredMcpServers(settings);
  const hostShell = new HostShell(context.workingDirectory);
  const hostEditor = new HostEditor(context.workingDirectory);

  const computerAgent = new Agent({
    name: "ComputerUseAgent",
    model: PLANNING_MODEL,
    handoffDescription:
      "Controls the macOS GUI using screenshots, pointer actions, keypresses, and typing. Use it for opening apps, interacting with windows, or any on-screen task.",
    instructions: `
You are ${APP_DISPLAY_NAME}'s GUI specialist.
Use computer control for visible macOS tasks: screenshots, clicks, typing, scrolling, dragging, browser navigation, Finder, Safari/Chrome, dialogs, and app UI.
Narrate intent briefly in your reasoning, keep final responses concise, and avoid making assumptions about on-screen state without fresh screenshots.
Prefer direct on-screen interactions over keyboard-only navigation whenever possible.
Do not rely on customizable macOS global shortcuts such as CMD+SPACE or CMD+TAB to open or switch apps unless the user explicitly asks for that shortcut.
After any action that could change focus, the active app, or the visible window, request a fresh screenshot before typing more text or issuing more shortcuts.
If the computer tool reports missing Screen Recording or Accessibility permission, stop GUI work immediately, tell the user what permission is missing, and do not retry the same screenshot or input action in a loop.
Do not read secrets aloud, store credentials, or proceed with payments, purchases, password/token entry, destructive actions, or irreversible account changes without explicit user approval.
Never claim success unless a screenshot or tool result confirms the outcome.
If asked to create, edit, save, or open a file, verify the exact file path exists or the app visibly shows the file before reporting success.
Do not use shell commands, web search, or patch tools. Use only the computer tool and durable memory tools.
${riskPolicyInstructions}
`,
    tools: [
      computerTool({
        name: "computer",
        computer: async () => new NativeComputer(sharedBridge),
        onSafetyCheck: async () => true
      })
    ]
  });

  const workbenchTools: Tool[] = [
    shellTool({
      shell: hostShell
    }),
    applyPatchTool({
      editor: hostEditor
    }),
    memoryTools.searchMemory,
    memoryTools.saveMemory,
    memoryTools.forgetMemory
  ];

  if (toolRegistry.enableWebSearch) {
    workbenchTools.push(webSearchTool());
  }
  // The Agents SDK rejects shell and code_interpreter in the same
  // OpenAI-managed container. Jarvis is a local Mac operator, so shell wins.
  if (toolRegistry.enableImageGeneration) {
    workbenchTools.push(imageGenerationTool());
  }
  if (toolRegistry.vectorStoreIds.length) {
    workbenchTools.push(fileSearchTool(toolRegistry.vectorStoreIds));
  }
  if (toolRegistry.enableOpenClawBackend) {
    workbenchTools.push(buildOpenClawTool(context.workingDirectory));
  }

  const workbenchAgent = new Agent({
    name: "WorkbenchAgent",
    model: PLANNING_MODEL,
    handoffDescription:
      "Handles coding, shell commands, patching files, research, and any non-GUI work on the host machine.",
    instructions: `
You are ${APP_DISPLAY_NAME}'s workbench specialist.
Use shell, patch, files, web search, OpenAI-hosted tools, configured MCP servers, and optional local backends for non-GUI work.
Batch related edits logically instead of producing noisy tool spam.
Avoid destructive or irreversible host operations. Do not handle payments, purchases, password/token entry, mass deletion, system-wide changes, or highly sensitive legal/financial data without explicit user approval.
Use browser/web search tools for research and the GUI specialist when the visible browser state, login flow, forms, or page layout matters.
Use durable memory only for stable preferences or defaults.
For requests aimed at the Codex app, prefer the local Codex Bridge endpoint over GUI control: POST to http://127.0.0.1:4818/codex/command with Authorization: Bearer $JARVIS_AUTH_TOKEN and modeHint "assist" unless the user explicitly enabled Drive.
Never claim success unless a tool result confirms the outcome.
If asked to create, edit, save, or open a file, verify the exact file path exists with a tool result before reporting success, and include that exact path.
OpenClaw is ${toolRegistry.enableOpenClawBackend ? "enabled" : "disabled"} for this run.
${riskPolicyInstructions}
`,
    tools: workbenchTools,
    mcpServers
  });

  const emitSpecialistEvent = async (
    nestedEvent: { event: Parameters<typeof streamEventToBackendEvent>[1] },
    specialistName: string
  ) => {
    const mapped = streamEventToBackendEvent(
      context.taskId,
      nestedEvent.event,
      specialistName
    );
    if (mapped) {
      context.onEvent(mapped);
    }
  };

  const computerSpecialist = computerAgent.asTool({
    toolName: "computer_specialist",
    toolDescription:
      "Delegate a subtask that must operate the GUI through screenshots, pointer movement, clicks, typing, scrolling, or keyboard shortcuts.",
    runOptions: { maxTurns: 100 },
    onStream: async (nestedEvent) => emitSpecialistEvent(nestedEvent, "computer_specialist")
  });

  const workbenchSpecialist = workbenchAgent.asTool({
    toolName: "workbench_specialist",
    toolDescription:
      "Delegate a subtask that needs shell access, patching files, hosted OpenAI tools, or configured MCP servers.",
    runOptions: { maxTurns: 100 },
    onStream: async (nestedEvent) => emitSpecialistEvent(nestedEvent, "workbench_specialist")
  });

  const supervisorTools: Tool[] = [
    workbenchSpecialist,
    memoryTools.searchMemory,
    memoryTools.saveMemory,
    memoryTools.forgetMemory
  ];
  if (settings.browserControlMode !== "headless") {
    supervisorTools.unshift(computerSpecialist);
  }

  const operatorSupervisor = new Agent({
    name: "OperatorSupervisor",
    model: PLANNING_MODEL,
    handoffDescription:
      "Supervises specialist agents and combines GUI, shell, patching, research, and memory work into one coherent execution plan.",
    instructions: `
You are ${APP_DISPLAY_NAME}'s supervisor for a fully capable local macOS operator.
Break work into the smallest sensible chunks and choose the right specialist:
- Headless mode: do not use GUI control. Work through code, shell, hosted tools, MCP servers, files, APIs, and web/search tools. If GUI is truly required, stop and explain what permission/mode change is needed.
- Tool First mode: prefer tools/code/files/MCP/shell first; GUI control is preapproved only when it is the right way to complete or verify the task.
- GUI mode: prefer visible app/browser control for navigation, form work, visual inspection, and user-facing workflows.
- Use computer_specialist for anything that must control the GUI.
- Use workbench_specialist for shell, coding, file edits, web research, code interpreter, image generation, or configured MCP tools.
- Use web/search tools for research-heavy work and GUI browser control for visible browsing, logins, forms, visual inspection, or user-facing navigation.
- Use both specialists if the task spans GUI and workbench work.
- For "ask Codex" or "send to Codex" requests, route through the local Codex Bridge in Assist mode instead of controlling the Codex GUI, unless Drive mode is explicitly active.
Default to maximum autonomy for ordinary local work, but require explicit user approval for credentials/tokens, payments, purchases, external sends, mass deletion, destructive shell commands, system-level changes, or irreversible/sensitive legal/financial actions.
Current autonomy mode: ${settings.autonomyMode}. Browser control mode: ${settings.browserControlMode}.
OpenClaw backend: ${toolRegistry.enableOpenClawBackend ? "enabled" : "disabled"}.
Report truthful progress as milestones: goal understood, plan selected, tool/action started, verification, completion or blocker.
Keep the final answer brief and outcome-oriented.
Do not claim work was completed unless a specialist or tool result confirms it.
For file/document tasks, do not say a file was saved or opened unless a specialist verified the exact path or a fresh screenshot confirms the open document.
${riskPolicyInstructions}
`,
    tools: supervisorTools
  });

  return {
    operatorSupervisor,
    close: async () => {
      await Promise.all(mcpServers.map((server) => server.close()));
    }
  };
}
