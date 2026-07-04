import AppKit
import AVFoundation
import Foundation

private enum VoiceConnectionError: Error {
  case timeout
}

enum ApiKeyValidationState: Equatable {
  case unknown
  case checking
  case valid
  case invalid(String)
}

@MainActor
final class AppModel: ObservableObject {
  @Published var health: HealthSnapshot = .offline
  @Published var settings: SettingsData = .empty
  @Published var apiKeyDraft = ""
  @Published var xaiKeyDraft = ""
  @Published var geminiKeyDraft = ""
  @Published var hotkeyDraft = ""
  @Published var commandDraft = ""
  @Published var memories: [MemoryRecord] = []
  @Published var events: [BackendEvent] = []
  @Published var permissions = NativePermissionSnapshot(
    microphone: "unknown",
    screen: "unknown",
    accessibilityTrusted: false,
    voiceRuntimeSupported: false
  )
  @Published var documentsAccessGranted = false
  @Published var apiKeyValidation: ApiKeyValidationState = .unknown
  @Published var pendingApproval: ApprovalRequest?
  @Published var pendingRealtimeApproval: VoiceApprovalState?
  @Published var activeTaskId: String?
  @Published var phase = "idle"
  @Published var voiceState = VoiceRuntimeState(
    connected: false,
    muted: false,
    phase: "idle",
    currentAgent: "ConversationAgent",
    level: 0
  )
  @Published var transcript: [TranscriptEntry] = []
  @Published var errorMessage = ""
  @Published var voiceRuntimeErrorMessage = ""
  @Published var sidecarReady = false
  @Published var overlayVisible = false
  @Published var listeningModeActive = false
  @Published var voiceProgressAnnouncementsEnabled = true
  @Published var lastHeartbeatAt: Date?
  @Published var codexStatus: CodexStatus = .empty
  @Published var agentsStatus: [AgentStatusRow] = []
  @Published var codexPmStatus: CodexPmStatus = .empty
  @Published var codexEvents: [CodexBridgeEvent] = []
  @Published var codexCommandDraft = ""

  private let client: SidecarClient
  private let sidecar: SidecarProcessController
  private let permissionCoordinator: PermissionCoordinator
  private var eventsTask: Task<Void, Never>?
  private var accessibilityRefreshTask: Task<Void, Never>?
  private var seenBackendEventIDs = Set<String>()
  private var terminalTaskIds = Set<String>()
  private var lastSpokenProgress = ""
  private var lastSpokenProgressAt = Date.distantPast
  private let progressSpeaker = AVSpeechSynthesizer()
  private weak var voiceController: VoiceRuntimeControlling?
  private var localVoiceController: LocalVoiceController?
  @Published var localVoiceHealth: SidecarClient.LocalVoiceHealth?
  @Published var parakeetReady = false
  /// Live readiness of the local models: "" when idle/ok, otherwise a
  /// human-readable "loading…" line shown in the Local Voice card.
  @Published var localWarmupStatus = ""
  private let nativeLogURL: URL = {
    let base = AppIdentity.logsDirectory()
    return base.appending(path: "native-overlay.log")
  }()

  init(
    permissionCoordinator: PermissionCoordinator = PermissionCoordinator(),
    localAuthToken: String = LocalAuthToken.generate()
  ) {
    self.permissionCoordinator = permissionCoordinator
    client = SidecarClient(authToken: localAuthToken)
    sidecar = SidecarProcessController(authToken: localAuthToken)
    permissions = permissionCoordinator.currentSnapshot()
  }

  func attachVoiceController(_ controller: VoiceRuntimeControlling) {
    voiceController = controller
  }

  private var isLocalProvider: Bool {
    settings.voiceProvider == "local"
  }

  private var localVoice: LocalVoiceController {
    if let existing = localVoiceController {
      return existing
    }
    let controller = LocalVoiceController(client: client)
    controller.onPhaseChange = { [weak self] phase in
      guard let self else { return }
      self.voiceState.phase = phase
      self.syncPhase()
    }
    controller.onError = { [weak self] message in
      guard let self else { return }
      self.errorMessage = message
      self.voiceState.phase = "idle"
      self.syncPhase()
    }
    controller.onUserTranscript = { [weak self] text in
      self?.appendLocalTranscript(role: "user", text: text)
    }
    controller.onAssistantReply = { [weak self] text in
      self?.appendLocalTranscript(role: "assistant", text: text)
    }
    localVoiceController = controller
    return controller
  }

  private func appendLocalTranscript(role: String, text: String) {
    transcript.append(
      TranscriptEntry(
        id: UUID().uuidString,
        role: role,
        text: text,
        timestamp: ISO8601DateFormatter().string(from: Date()),
        agent: role == "assistant" ? "Jarvis" : nil
      ))
    if transcript.count > 200 {
      transcript.removeFirst(transcript.count - 200)
    }
  }

  func shutdown() {
    sidecar.terminate()
  }

  func bootstrap() async {
    do {
      try await sidecar.ensureRunning(using: client)
      sidecarReady = true
      await refresh()
      startEventStreamIfNeeded()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func refresh(includeHealth: Bool = true) async {
    var firstError: Error?

    do {
      let nextSettings = try await client.settings()
      settings = nextSettings
      apiKeyDraft = ""
      hotkeyDraft = nextSettings.hotkey
    } catch {
      firstError = firstError ?? error
    }

    do {
      memories = try await client.recentMemories(limit: 8)
    } catch {
      firstError = firstError ?? error
    }

    do {
      codexStatus = try await client.codexStatus()
      codexEvents = try await client.recentCodexEvents(limit: 24)
    } catch {
      firstError = firstError ?? error
    }

    setPermissions(permissionCoordinator.refresh(force: true))

    if includeHealth {
      do {
        health = try await client.health()
      } catch {
        firstError = firstError ?? error
      }
    }

    if let firstError {
      errorMessage = firstError.localizedDescription
    } else {
      errorMessage = ""
    }
    syncPhase()
  }

  func refreshStatus() async {
    var nextError = errorMessage

    setPermissions(permissionCoordinator.refresh(force: true))

    do {
      health = try await client.health()
      codexStatus = try await client.codexStatus()
      codexEvents = try await client.recentCodexEvents(limit: 24)
      if let agents = try? await client.agentsStatus() {
        agentsStatus = agents.agents
      }
      sidecarReady = true
      lastHeartbeatAt = Date()
      if nextError == SidecarStartupError.failedToBecomeHealthy.localizedDescription {
        nextError = ""
      }
    } catch {
      nextError = error.localizedDescription
    }

    errorMessage = nextError
    syncPhase()
  }

  func overlayActivated() async {
    overlayVisible = true
    if !sidecarReady || hasBlockingSetupIssue {
      await refresh()
      return
    }
    syncPhase()
  }

  func overlayDeactivated() async {
    overlayVisible = false
    listeningModeActive = false
    await voiceController?.close()
    resetVoiceState()
    voiceRuntimeErrorMessage = ""
    pendingRealtimeApproval = nil
    syncPhase()
  }

  func saveApiKey() async {
    do {
      let nextSettings = try await client.updateSettings(
        SettingsPatch(apiKey: apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines))
      )
      settings = nextSettings
      apiKeyDraft = ""
      setPermissions(permissionCoordinator.refresh(force: true))
      errorMessage = ""

      Task {
        await refresh(includeHealth: false)
      }

      syncPhase()
      await validateApiKey()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func saveVoiceProvider(_ provider: String) async {
    do {
      settings = try await client.updateSettings(SettingsPatch(voiceProvider: provider))
      errorMessage = ""
      syncPhase()
      if provider == "local" {
        applyLocalVoiceConfig()
        await warmLocalModels()
      }
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func refreshLocalVoiceHealth() async {
    localVoiceHealth = try? await client.localVoiceHealth()
    parakeetReady = (try? await client.parakeetReady()) ?? false
  }

  /// Guards against overlapping warmups (double-clicking "Reload / warm
  /// models", or an engine switch racing a Connect) — concurrent runs would
  /// interleave their writes to `localWarmupStatus`.
  private var warmupInFlight = false

  /// Warms the local models (LLM into memory, Parakeet inference path) and
  /// publishes a live status the Local Voice card renders. Safe to call on
  /// connect and after any engine/provider switch.
  func warmLocalModels() async {
    guard !warmupInFlight else { return }
    warmupInFlight = true
    defer { warmupInFlight = false }
    let english = assistantLanguage == "en"
    localWarmupStatus = english ? "Loading local model…" : "Cargando modelo local…"
    async let llm: () = warmLocalLLM()
    if (settings.localSttEngine ?? "apple") == "parakeet" {
      LocalVoiceController.warmUpParakeet()
      await waitForParakeet(english: english)
    }
    await llm
    localWarmupStatus = ""
    await refreshLocalVoiceHealth()
  }

  private func warmLocalLLM() async {
    _ = try? await client.localVoiceWarmup()
  }

  private func waitForParakeet(english: Bool) async {
    localWarmupStatus = english ? "Loading Parakeet speech model…" : "Cargando el modelo de voz Parakeet…"
    var unreachable = 0
    for _ in 0 ..< 40 {  // up to ~40 s on first download
      switch await client.parakeetHealth() {
      case .ready:
        parakeetReady = true
        return
      case .loading:
        unreachable = 0
      case .unreachable:
        // The Parakeet LaunchAgent isn't answering; a couple of misses means
        // it's down, so stop instead of burning the full 40 s. The card's
        // "not ready" pill surfaces the state to the user.
        unreachable += 1
        if unreachable >= 3 {
          parakeetReady = false
          return
        }
      }
      try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
  }

  func saveLocalSttEngine(_ engine: String) async {
    do {
      settings = try await client.updateSettings(SettingsPatch(localSttEngine: engine))
      // Hot-switching mid-capture would leave the old engine's pipeline
      // half-running (no recognizer / stale accumulator) and go silent:
      // stop cleanly and re-arm hands-free once the engine is warm.
      // listeningModeActive is the local pipeline's own flag — more reliable
      // than voiceState, which web-runtime events could have clobbered.
      let wasListening = listeningModeActive || (voiceState.connected && !voiceState.muted)
      localVoiceController?.stop()
      applyLocalVoiceConfig()
      errorMessage = ""
      syncPhase()
      await warmLocalModels()
      if wasListening {
        // Seamless: resume listening automatically once warm. Restore
        // connected too — a stray web-runtime event may have cleared it.
        voiceState.connected = true
        voiceState.muted = false
        listeningModeActive = true
        localVoice.startListeningIfIdle(continuous: true)
      }
    } catch {
      errorMessage = error.localizedDescription
    }
    syncPhase()
  }

  func saveBargeIn(_ enabled: Bool) async {
    do {
      settings = try await client.updateSettings(SettingsPatch(bargeInEnabled: enabled))
      applyLocalVoiceConfig()
      errorMessage = ""
    } catch {
      errorMessage = error.localizedDescription
    }
    syncPhase()
  }

  private func applyLocalVoiceConfig() {
    // Uses the getter so the controller is created on first use (the connect
    // and listening paths configure before starting capture).
    localVoice.configure(
      language: assistantLanguage,
      sttEngine: settings.localSttEngine ?? "apple",
      bargeIn: settings.bargeInEnabled ?? true)
  }

  func saveGrokVoice(_ voice: String) async {
    do {
      settings = try await client.updateSettings(SettingsPatch(grokVoice: voice))
      errorMessage = ""
    } catch {
      errorMessage = error.localizedDescription
    }
    syncPhase()
  }

  func saveGeminiVoice(_ voice: String) async {
    do {
      settings = try await client.updateSettings(SettingsPatch(geminiVoice: voice))
      errorMessage = ""
    } catch {
      errorMessage = error.localizedDescription
    }
    syncPhase()
  }

  func saveXaiKey() async {
    let trimmed = xaiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      settings = try await client.updateSettings(SettingsPatch(xaiApiKey: trimmed))
      xaiKeyDraft = ""
      errorMessage = ""
      syncPhase()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func saveGeminiKey() async {
    let trimmed = geminiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      settings = try await client.updateSettings(SettingsPatch(geminiApiKey: trimmed))
      geminiKeyDraft = ""
      errorMessage = ""
      syncPhase()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  /// Mints a throwaway Realtime client secret — the exact call voice needs —
  /// so a bad or credit-less key surfaces here instead of at first connect.
  func validateApiKey() async {
    guard settings.hasApiKey else {
      apiKeyValidation = .unknown
      return
    }
    apiKeyValidation = .checking
    do {
      let result = try await client.validateApiKey()
      apiKeyValidation = result.valid
        ? .valid
        : .invalid(result.reason ?? "OpenAI rejected the API key.")
    } catch {
      // Sidecar unreachable is not a key problem; leave state undetermined.
      apiKeyValidation = .unknown
    }
  }

  func saveHotkey() async {
    let trimmed = hotkeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      let nextSettings = try await client.updateSettings(SettingsPatch(hotkey: trimmed))
      settings = nextSettings
      hotkeyDraft = nextSettings.hotkey
      syncPhase()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func saveVoice(_ voice: String) async {
    let trimmed = voice.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != settings.voice else { return }
    let wasConnected = voiceState.connected
    let shouldStartMuted = voiceConnectsMuted

    do {
      let nextSettings = try await client.updateSettings(SettingsPatch(voice: trimmed))
      settings = nextSettings
      errorMessage = ""

      if wasConnected {
        await voiceController?.close()
        resetVoiceState()
        await connectVoice(startMuted: shouldStartMuted)
      } else {
        syncPhase()
      }
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func saveVoiceInputMode(_ mode: String) async {
    let normalized = normalizedVoiceInputMode(mode)
    guard normalized != settings.voiceInputMode else { return }

    do {
      let nextSettings = try await client.updateSettings(SettingsPatch(voiceInputMode: normalized))
      settings = nextSettings
      listeningModeActive = normalized == "continuous" && voiceState.connected
      errorMessage = ""

      if voiceState.connected {
        await applyVoiceInputMode()
      } else {
        syncPhase()
      }
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  var assistantLanguage: String {
    settings.language == "en" ? "en" : "es"
  }

  func saveAssistantLanguage(_ language: String) async {
    let normalized = language == "en" ? "en" : "es"
    guard normalized != assistantLanguage else { return }

    do {
      let nextSettings = try await client.updateSettings(SettingsPatch(language: normalized))
      settings = nextSettings
      errorMessage = ""

      // The realtime session bakes the language directive into the agent
      // instructions at connect time, so an active session must reconnect.
      if voiceState.connected {
        let wasMuted = voiceState.muted
        await disconnectVoice()
        await connectVoice(startMuted: wasMuted)
      } else {
        syncPhase()
      }
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func saveBrowserControlMode(_ mode: String) async {
    let normalized = normalizedBrowserControlMode(mode)
    guard normalized != settings.browserControlMode else { return }

    do {
      let nextSettings = try await client.updateSettings(SettingsPatch(browserControlMode: normalized))
      settings = nextSettings
      errorMessage = ""
      syncPhase()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func saveCodexBridgeMode(_ mode: String) async {
    let normalized = normalizedCodexBridgeMode(mode)
    guard normalized != settings.codexIntegration.mode else { return }

    var nextIntegration = settings.codexIntegration
    nextIntegration.mode = normalized
    nextIntegration.driveExpiresAt = normalized == "drive" && !nextIntegration.godMode
      ? ISO8601DateFormatter().string(from: Date().addingTimeInterval(600))
      : nil

    do {
      let nextSettings = try await client.updateSettings(SettingsPatch(codexIntegration: nextIntegration))
      settings = nextSettings
      errorMessage = ""
      await refreshCodex()
      syncPhase()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func saveCodexGodMode(_ enabled: Bool) async {
    guard enabled != settings.codexIntegration.godMode else { return }
    let wasVoiceConnected = voiceState.connected
    let reconnectMuted = voiceState.muted || voiceConnectsMuted

    var nextIntegration = settings.codexIntegration
    nextIntegration.enabled = true
    nextIntegration.godMode = enabled
    if enabled {
      nextIntegration.mode = "drive"
      nextIntegration.driveExpiresAt = nil
    } else if nextIntegration.mode == "drive" {
      nextIntegration.mode = "assist"
      nextIntegration.driveExpiresAt = nil
    }

    do {
      let nextSettings = try await client.updateSettings(SettingsPatch(codexIntegration: nextIntegration))
      settings = nextSettings
      errorMessage = ""
      await refreshCodex()
      if wasVoiceConnected {
        await voiceController?.close()
        resetVoiceState()
        await connectVoice(startMuted: reconnectMuted)
      }
      syncPhase()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func sendCodexPrompt(modeHint: String? = nil) async {
    let trimmed = codexCommandDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    do {
      let result = try await client.sendCodexCommand(CodexCommandRequest(
        intent: "control_center",
        command: trimmed,
        modeHint: modeHint ?? settings.codexIntegration.mode,
        requireConfirmation: nil
      ))
      if !result.needsUserApproval {
        codexCommandDraft = ""
      }
      errorMessage = result.status == "error" ? result.summary : ""
      await refreshCodex()
      if result.status == "sent" {
        await readCodexPmStatus(query: "Read the current Codex response after Jarvis sent a PM brief.")
      }
      syncPhase()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func readCodexPmStatus(query: String? = nil) async {
    await readAgentPmStatus("codex", query: query)
  }

  func readAgentPmStatus(_ agent: String, query: String? = nil) async {
    do {
      codexPmStatus = try await client.codexPmStatus(query: query, agent: agent)
      await refreshCodex()
      errorMessage = codexPmStatus.ok ? "" : codexPmStatus.summary
      syncPhase()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func stopCodexBridge() async {
    do {
      _ = try await client.stopCodexBridge()
      codexPmStatus = .empty
      await refreshCodex()
      syncPhase()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func requestPermissions() async {
    setPermissions(await permissionCoordinator.requestMicrophone())
    setPermissions(await permissionCoordinator.requestScreenRecording())

    let accessibilitySnapshot = permissionCoordinator.requestAccessibility()
    setPermissions(accessibilitySnapshot)
    if accessibilitySnapshot.accessibilityTrusted {
      accessibilityRefreshTask?.cancel()
      accessibilityRefreshTask = nil
    } else {
      beginAccessibilityTrustPolling()
    }

    setPermissions(permissionCoordinator.refresh(force: true))
    syncPhase()
  }

  func requestMicrophonePermission() async {
    setPermissions(await permissionCoordinator.requestMicrophone())
    syncPhase()
  }

  func requestScreenPermission() async {
    setPermissions(await permissionCoordinator.requestScreenRecording())
    syncPhase()
  }

  func requestAccessibilityPermission() async {
    let snapshot = permissionCoordinator.requestAccessibility()
    setPermissions(snapshot)
    syncPhase()

    if snapshot.accessibilityTrusted {
      accessibilityRefreshTask?.cancel()
      accessibilityRefreshTask = nil
    } else {
      beginAccessibilityTrustPolling()
    }
  }

  /// First read of ~/Documents makes macOS show its files-access dialog (there
  /// is no request API for folder permissions, unlike microphone).
  func requestDocumentsAccess() async {
    let granted = await Task.detached(priority: .userInitiated) { () -> Bool in
      let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
      guard let documents else { return false }
      return (try? FileManager.default.contentsOfDirectory(atPath: documents.path)) != nil
    }.value
    documentsAccessGranted = granted
  }

  func refreshPermissions(force: Bool = false) {
    setPermissions(permissionCoordinator.refresh(force: force))
    syncPhase()
  }

  func applicationDidBecomeActive() {
    refreshPermissions(force: true)
  }

  func connectVoice(startMuted: Bool = true) async {
    guard sidecarReady else {
      errorMessage = "The local sidecar is not ready yet."
      syncPhase()
      return
    }

    // Right after launch `settings` can still be the empty placeholder
    // (provider "openai"); deciding the connect path on stale data sent
    // local-provider connects into the web runtime. Refresh first.
    if let freshSettings = try? await client.settings() {
      settings = freshSettings
    }

    // The local provider never uses the WKWebView realtime runtime: Connect
    // just arms push-to-talk (or starts listening right away when unmuted).
    if isLocalProvider {
      errorMessage = ""
      voiceRuntimeErrorMessage = ""
      voiceState.connected = true
      voiceState.muted = startMuted
      voiceState.phase = startMuted ? "idle" : "listening"
      listeningModeActive = !startMuted
      applyLocalVoiceConfig()
      if let health = localVoiceHealth, !health.running || !health.modelPulled {
        errorMessage = health.running
          ? "Ollama is missing the model — run: ollama pull \(health.model)"
          : "Ollama is not running. Start it or reinstall from ollama.com."
      }
      syncPhase()
      // Warm both legs of the pipeline (published status shown in the card),
      // then start listening if unmuted — the first turn answers fast.
      await warmLocalModels()
      if !startMuted {
        await localVoice.startListening(continuous: true)
      }
      return
    }

    if hasBlockingSetupIssue {
      errorMessage = permissions.voiceRuntimeSupported
        ? "Finish setup before starting voice."
        : "Launch Jarvis from the bundled app so WebKit voice capture can access the microphone."
      syncPhase()
      return
    }

    guard voiceController != nil else {
      errorMessage = "The native voice runtime is still loading."
      syncPhase()
      return
    }

    errorMessage = ""
    voiceRuntimeErrorMessage = ""
    voiceState.phase = "connecting"
    listeningModeActive = false
    logNativeOverlay("Voice connect requested. startMuted=\(startMuted)")
    syncPhase()

    let connectTask = Task { [weak self] in
      try await self?.voiceController?.connect(startMuted: startMuted)
    }

    let timeoutTask = Task {
      try await Task.sleep(nanoseconds: 20_000_000_000)
      connectTask.cancel()
    }

    do {
      try await connectTask.value
      timeoutTask.cancel()
      if voiceState.phase == "connecting" {
        // JS connect succeeded but voice state event hasn't arrived yet.
        voiceState.connected = true
        voiceState.phase = startMuted ? "idle" : "listening"
        voiceState.muted = startMuted
        listeningModeActive = !startMuted
        errorMessage = ""
        syncPhase()
      }
    } catch is CancellationError {
      timeoutTask.cancel()
      listeningModeActive = false
      resetVoiceState()
      errorMessage = "Voice connection timed out. Check your API key and network."
      logNativeOverlay("Voice connect timed out.")
      syncPhase()
    } catch {
      timeoutTask.cancel()
      listeningModeActive = false
      resetVoiceState()
      let usefulMessage = voiceRuntimeErrorMessage.isEmpty
        ? error.localizedDescription
        : voiceRuntimeErrorMessage
      errorMessage = usefulMessage
      logNativeOverlay("Voice connect failed: \(usefulMessage)")
      syncPhase()
    }
  }

  func disconnectVoice() async {
    listeningModeActive = false
    if isLocalProvider {
      localVoiceController?.stop()
    } else {
      await voiceController?.close()
    }
    resetVoiceState()
    voiceRuntimeErrorMessage = ""
    syncPhase()
  }

  // MARK: - Listening Mode

  func startListening() async {
    if isLocalProvider {
      listeningModeActive = true
      overlayVisible = true
      errorMessage = ""
      voiceRuntimeErrorMessage = ""
      applyLocalVoiceConfig()
      await localVoice.startListening()
      return
    }
    let wasSpeaking = voiceState.phase == "speaking" || phase == "speaking"
    listeningModeActive = true
    overlayVisible = true
    errorMessage = ""
    voiceRuntimeErrorMessage = ""
    voiceState.muted = false
    voiceState.phase = "listening"
    syncPhase()
    if voiceState.connected && wasSpeaking {
      await voiceController?.interrupt()
    }
    if !voiceState.connected {
      await connectVoice(startMuted: false)
      return
    }
    await setVoiceMuted(false)
  }

  func stopListening() async {
    if isLocalProvider {
      listeningModeActive = false
      await localVoice.stopListeningAndRespond()
      return
    }
    listeningModeActive = false
    syncPhase()
    await setVoiceMuted(true)
  }

  func toggleListeningFromSettings() async {
    if isLocalProvider {
      if !voiceState.connected {
        await connectVoice(startMuted: false)
        return
      }
      if voiceState.muted {
        // Button = hands-free conversation: silence auto-commits each turn
        // and listening resumes after the reply. Hotkey stays push-to-talk.
        voiceState.muted = false
        listeningModeActive = true
        applyLocalVoiceConfig()
        await localVoice.startListening(continuous: true)
      } else {
        voiceState.muted = true
        listeningModeActive = false
        // Hard stop: muting must release the mic (and cut any reply)
        // immediately and DISCARD what was mid-capture — committing it as a
        // turn kept the pipeline talking/listening after the user muted.
        localVoice.stop()
      }
      syncPhase()
      return
    }
    if !voiceState.connected {
      await connectVoice(startMuted: false)
      return
    }
    await setVoiceMuted(!voiceState.muted)
  }

  func setVoiceMuted(_ muted: Bool) async {
    guard voiceState.connected else {
      syncPhase()
      return
    }
    // The local pipeline is not driven by the web runtime: route mute/unmute
    // to the controller directly, or the mic keeps capturing behind a
    // muted-looking UI.
    if isLocalProvider {
      voiceState.muted = muted
      listeningModeActive = !muted
      if muted {
        localVoiceController?.stop()
      } else {
        applyLocalVoiceConfig()
        await localVoice.startListening(continuous: true)
      }
      syncPhase()
      return
    }
    // Mark intent before the runtime round-trip: the resulting state event
    // arrives before this method resumes, and the push-to-talk guard would
    // otherwise re-mute immediately because listeningModeActive is stale.
    listeningModeActive = !muted
    do {
      try await voiceController?.setMuted(muted)
    } catch {
      listeningModeActive = false
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  var voiceInputMode: String {
    normalizedVoiceInputMode(settings.voiceInputMode)
  }

  var usesPushToTalk: Bool {
    voiceInputMode == "push_to_talk"
  }

  var voiceConnectsMuted: Bool {
    voiceInputMode != "continuous"
  }

  var executionModeLabel: String {
    switch settings.browserControlMode {
    case "headless":
      return "Headless"
    case "tool_first", "hybrid":
      return "Tool First"
    case "gui":
      return "GUI"
    default:
      return "Hybrid"
    }
  }

  var runtimeHeartbeatLabel: String {
    guard let lastHeartbeatAt else {
      return "Waiting"
    }
    let age = max(0, Int(Date().timeIntervalSince(lastHeartbeatAt)))
    return age <= 1 ? "Live" : "\(age)s ago"
  }

  var backendQueueLabel: String {
    let ids = health.activeTaskIds ?? []
    if ids.isEmpty {
      return activeTaskId == nil ? "Empty" : "1 active"
    }
    return "\(ids.count) active"
  }

  var codexModeLabel: String {
    if settings.codexIntegration.godMode {
      return codexStatus.mode == "drive" ? "God Mode" : "God Assist"
    }
    switch codexStatus.mode {
    case "observe":
      return "Observe"
    case "drive":
      return "Drive"
    default:
      return "Assist"
    }
  }

  var codexQueueLabel: String {
    codexStatus.queueDepth == 0 ? "Empty" : "\(codexStatus.queueDepth) pending"
  }

  var codexHeartbeatLabel: String {
    guard !codexStatus.heartbeatAt.isEmpty,
          let date = ISO8601DateFormatter().date(from: codexStatus.heartbeatAt) else {
      return "Waiting"
    }
    let age = max(0, Int(Date().timeIntervalSince(date)))
    return age <= 1 ? "Live" : "\(age)s ago"
  }

  /// Outcome of the most recent prompt delivery, from the sidecar's event log.
  /// (label, confirmed) — confirmed=false means blind delivery: pasted and sent
  /// but Accessibility could not read the text back.
  var lastDeliveryBadge: (label: String, confirmed: Bool)? {
    guard let event = codexEvents.first(where: { $0.type == "sent" }) else {
      return nil
    }
    switch event.detail {
    case "delivery:verified":
      return ("Verified", true)
    case "delivery:blind":
      return ("Sent (unconfirmed — check the agent window)", false)
    default:
      return nil
    }
  }

  var codexPmStateLabel: String {
    switch codexPmStatus.currentState {
    case "offline":
      return "Offline"
    case "idle":
      return "Idle"
    case "working":
      return "Working"
    case "needs_user":
      return "Needs You"
    default:
      return "Unknown"
    }
  }

  func interruptVoice() async {
    // Local pipeline: "Stop" cuts the reply being spoken but keeps the
    // conversation armed; the web runtime has its own interrupt.
    if isLocalProvider {
      localVoiceController?.interruptPlayback()
      return
    }
    await voiceController?.interrupt()
  }

  func approveRealtimeApproval() async {
    guard pendingRealtimeApproval != nil else {
      return
    }

    do {
      try await voiceController?.approveApproval(alwaysApprove: false)
      pendingRealtimeApproval = nil
      voiceState.phase = "thinking"
      syncPhase()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func rejectRealtimeApproval() async {
    guard pendingRealtimeApproval != nil else {
      return
    }

    do {
      try await voiceController?.rejectApproval(
        message: "That memory action was rejected by the user.",
        alwaysReject: false
      )
      pendingRealtimeApproval = nil
      voiceState.phase = "thinking"
      syncPhase()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func startTask() async {
    let request = commandDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !request.isEmpty else {
      return
    }

    do {
      let started = try await client.startTask(userRequest: request)
      activeTaskId = started.taskId
      commandDraft = ""
      prependSyntheticEvent(
        type: "started",
        taskId: started.taskId,
        summary: "Task submitted to the operator."
      )
      syncPhase()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func approvePending() async {
    guard let approval = pendingApproval else {
      return
    }

    do {
      try await client.approve(taskId: approval.taskId, approvalId: approval.id)
      pendingApproval = nil
      syncPhase()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func rejectPending() async {
    guard let approval = pendingApproval else {
      return
    }

    do {
      try await client.reject(
        taskId: approval.taskId,
        approvalId: approval.id,
        message: "Rejected from the native overlay."
      )
      pendingApproval = nil
      syncPhase()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func cancelActiveTask() async {
    guard let activeTaskId else {
      return
    }

    do {
      try await client.cancel(taskId: activeTaskId)
      self.activeTaskId = nil
      syncPhase()
    } catch {
      errorMessage = error.localizedDescription
      syncPhase()
    }
  }

  func stopAllActivity() async {
    let knownActiveTaskId = activeTaskId

    do {
      let response = try await client.cancelAllTasks()
      for taskId in response.cancelled ?? [] {
        terminalTaskIds.insert(taskId)
      }
      try? await client.stopCodexBridge()
      codexPmStatus = .empty
    } catch {
      errorMessage = error.localizedDescription
    }

    if let knownActiveTaskId {
      terminalTaskIds.insert(knownActiveTaskId)
      try? await client.cancel(taskId: knownActiveTaskId)
    }

    if pendingApproval != nil {
      await rejectPending()
    }
    if pendingRealtimeApproval != nil {
      await rejectRealtimeApproval()
    }
    await disconnectVoice()
    activeTaskId = nil
    pendingApproval = nil
    pendingRealtimeApproval = nil
    listeningModeActive = false
    overlayVisible = false
    prependSyntheticEvent(type: "cancelled", taskId: knownActiveTaskId ?? "local-stop-all", summary: "Stop All cancelled local voice and backend activity.")
    syncPhase()
  }

  func statusLine(for event: BackendEvent) -> String {
    if let summary = event.summary, !summary.isEmpty {
      return summary
    }
    if let approval = event.approval {
      return approval.summary
    }
    if let result = event.result {
      return result.summary
    }
    if event.type == "screenshot" {
      return "Computer returned a fresh screenshot."
    }
    return event.type
  }

  var compactStatus: String {
    if let realtime = pendingRealtimeApproval {
      return realtime.title
    }

    if let approval = pendingApproval {
      return approval.summary
    }

    if let activeTaskId,
       let event = events.first(where: { $0.taskId == activeTaskId }) {
      return statusLine(for: event)
    }

    if let latest = events.first {
      return statusLine(for: latest)
    }

    if hasBlockingSetupIssue {
      return "Setup required before Jarvis can listen."
    }

    switch phase {
    case "connecting":
      return "Connecting to realtime voice."
    case "listening":
      return "Listening."
    case "thinking":
      return "Thinking."
    case "speaking":
      return "Speaking."
    case "acting":
      return "Working on your request."
    case "approvals":
      return "Waiting for approval."
    case "error":
      return displayErrorMessage.isEmpty ? "Something failed." : displayErrorMessage
    default:
      if voiceState.connected {
        return "Press Option+Space to listen."
      }
      return "Press Option+Space to listen."
    }
  }

  var hasBlockingSetupIssue: Bool {
    !settings.hasApiKey ||
      !health.inputServerAvailable ||
      !permissions.voiceRuntimeSupported ||
      permissions.microphone != "granted" ||
      permissions.screen != "granted" ||
      !permissions.accessibilityTrusted
  }

  var shouldExpandOverlay: Bool {
    false
  }

  var overlayActionCallout: OverlayActionCallout? {
    guard pendingApproval == nil, pendingRealtimeApproval == nil else {
      return nil
    }

    guard let activeTaskId else {
      return nil
    }

    if let event = latestOverlayActionEvent(for: activeTaskId) {
      return makeActionCallout(for: event)
    }

    return OverlayActionCallout(label: "Operator", text: "Preparing the operator.")
  }

  var canAutoHideOverlay: Bool {
    overlayVisible &&
      !listeningModeActive &&
      phase == "idle" &&
      pendingApproval == nil &&
      pendingRealtimeApproval == nil &&
      activeTaskId == nil
  }

  var displayErrorMessage: String {
    if !errorMessage.isEmpty {
      return errorMessage
    }
    return voiceRuntimeErrorMessage
  }

  func handleVoiceEvent(_ event: VoiceBridgeEvent) {
    switch event {
    case .ready:
      logNativeOverlay("Voice runtime ready.")
    case .state(let state):
      // The WKWebView runtime keeps emitting state events (connected=false on
      // load, idle heartbeats) even when the LOCAL provider owns the voice
      // pipeline. Letting them through clobbers voiceState — an engine
      // hot-switch then reads connected=false, concludes nothing was
      // listening, and never re-arms capture.
      guard !isLocalProvider else {
        break
      }
      voiceState = state
      if state.phase != "error" {
        voiceRuntimeErrorMessage = ""
      }
      if state.connected && voiceInputMode == "continuous" && state.muted {
        listeningModeActive = true
        Task { await setVoiceMuted(false) }
      } else if state.connected && !listeningModeActive && !state.muted && voiceInputMode != "continuous" {
        Task { await setVoiceMuted(true) }
      }
      logNativeOverlay(
        "Voice state connected=\(state.connected) muted=\(state.muted) phase=\(state.phase) level=\(state.level)"
      )
      syncPhase()
    case .transcript(let entries):
      transcript = entries
    case .realtimeApproval(let approval):
      pendingRealtimeApproval = approval
      syncPhase()
    case .error(let message):
      // Same isolation as .state: a web-runtime error must not tear down the
      // local pipeline's listening mode. Log it and move on.
      guard !isLocalProvider else {
        logNativeOverlay("Voice runtime error (ignored, local provider active): \(message)")
        break
      }
      voiceRuntimeErrorMessage = message
      if !voiceState.connected {
        listeningModeActive = false
      }
      if !voiceState.connected && activeTaskId == nil && pendingApproval == nil && pendingRealtimeApproval == nil {
        voiceState.phase = "error"
      }
      logNativeOverlay("Voice runtime error: \(message)")
      syncPhase()
    case .memoryChanged:
      Task {
        await refresh()
      }
    case .taskState(let taskId):
      activeTaskId = taskId
      syncPhase()
    }
  }

  private func setPermissions(_ snapshot: NativePermissionSnapshot) {
    permissions = snapshot
    if snapshot.accessibilityTrusted {
      accessibilityRefreshTask?.cancel()
      accessibilityRefreshTask = nil
    }
  }

  private func normalizedVoiceInputMode(_ mode: String) -> String {
    switch mode {
    case "continuous", "manual", "push_to_talk":
      return mode
    default:
      return "push_to_talk"
    }
  }

  private func normalizedBrowserControlMode(_ mode: String) -> String {
    switch mode {
    case "headless", "tool_first", "gui":
      return mode
    case "hybrid":
      return "tool_first"
    default:
      return "headless"
    }
  }

  private func normalizedCodexBridgeMode(_ mode: String) -> String {
    switch mode {
    case "observe", "assist", "drive":
      return mode
    default:
      return "assist"
    }
  }

  private func refreshCodex() async {
    do {
      codexStatus = try await client.codexStatus()
      codexEvents = try await client.recentCodexEvents(limit: 24)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func applyVoiceInputMode() async {
    switch voiceInputMode {
    case "continuous":
      listeningModeActive = true
      await setVoiceMuted(false)
    default:
      listeningModeActive = false
      await setVoiceMuted(true)
    }
  }

  private func beginAccessibilityTrustPolling() {
    accessibilityRefreshTask?.cancel()
    accessibilityRefreshTask = Task { [weak self] in
      guard let self else {
        return
      }

      for _ in 0..<20 {
        try? await Task.sleep(for: .milliseconds(750))
        if Task.isCancelled {
          return
        }

        self.refreshPermissions(force: true)
        if self.permissions.accessibilityTrusted {
          return
        }
      }
    }
  }

  private func startEventStreamIfNeeded() {
    guard eventsTask == nil else {
      return
    }

    eventsTask = Task { [weak self] in
      guard let self else {
        return
      }

      while !Task.isCancelled {
        do {
          let recentEvents = try await client.recentBackendEvents(limit: 48)
          applyRecentBackendEvents(recentEvents)
          try? await Task.sleep(for: .milliseconds(350))
        } catch {
          if Task.isCancelled {
            return
          }
          logNativeOverlay("Recent backend event poll failed: \(error.localizedDescription)")
          try? await Task.sleep(for: .seconds(1))
        }
      }
    }
  }

  private func handle(event: BackendEvent) {
    let wasTerminal = terminalTaskIds.contains(event.taskId)
    let isTerminal = event.type == "completed" || event.type == "failed" || event.type == "cancelled"

    if wasTerminal && !isTerminal {
      logNativeOverlay("Ignored late backend event \(event.type) for terminal task \(event.taskId)")
      return
    }

    if event.type == "started" {
      terminalTaskIds.remove(event.taskId)
    } else if isTerminal {
      terminalTaskIds.insert(event.taskId)
    }

    events.insert(event, at: 0)
    if events.count > 24 {
      events.removeLast(events.count - 24)
    }

    switch event.type {
    case "started":
      activeTaskId = event.taskId
    case "delegated", "tool_started", "screenshot":
      if activeTaskId == nil && !terminalTaskIds.contains(event.taskId) {
        activeTaskId = event.taskId
      }
    case "approval_requested":
      if !terminalTaskIds.contains(event.taskId) {
        pendingApproval = event.approval
      }
    case "approved", "rejected":
      if pendingApproval?.id == event.approvalId {
        pendingApproval = nil
      }
    case "completed":
      activeTaskId = nil
      pendingApproval = nil
      Task {
        await refresh(includeHealth: false)
      }
    case "failed":
      activeTaskId = nil
      errorMessage = event.summary ?? "The task failed."
    case "cancelled":
      activeTaskId = nil
    default:
      break
    }
    speakProgress(for: event)
    if let callout = overlayActionCallout {
      logNativeOverlay("Overlay callout -> [\(callout.label)] \(callout.text)")
    } else {
      logNativeOverlay("Overlay callout cleared.")
    }
    syncPhase()
  }

  private func speakProgress(for event: BackendEvent) {
    guard voiceProgressAnnouncementsEnabled else {
      return
    }

    let english = assistantLanguage == "en"
    let announcement: String?
    switch event.type {
    case "started":
      announcement = english ? "Jarvis started the task." : "Jarvis inició la tarea."
    case "delegated":
      announcement = english ? "Jarvis is working in the background." : "Jarvis está trabajando en segundo plano."
    case "tool_started":
      announcement = english ? "Jarvis is using a tool." : "Jarvis está usando una herramienta."
    case "approval_requested":
      announcement = english ? "Jarvis needs approval." : "Jarvis necesita aprobación."
    case "completed":
      announcement = english ? "Jarvis finished the task." : "Jarvis terminó la tarea."
    case "failed":
      announcement = english ? "Jarvis hit an error." : "Jarvis encontró un error."
    case "cancelled":
      announcement = english ? "Jarvis stopped the task." : "Jarvis detuvo la tarea."
    default:
      announcement = nil
    }

    guard let announcement else {
      return
    }

    let now = Date()
    guard announcement != lastSpokenProgress || now.timeIntervalSince(lastSpokenProgressAt) > 8 else {
      return
    }

    lastSpokenProgress = announcement
    lastSpokenProgressAt = now
    if progressSpeaker.isSpeaking {
      progressSpeaker.stopSpeaking(at: .immediate)
    }
    let utterance = AVSpeechUtterance(string: announcement)
    // Announcements are built in the assistant language; pick a matching
    // voice so Spanish text is not read with English phonetics.
    utterance.voice = AVSpeechSynthesisVoice(language: english ? "en-US" : "es-ES")
    progressSpeaker.speak(utterance)
  }

  private func prependSyntheticEvent(type: String, taskId: String, summary: String) {
    let event = BackendEvent(
      taskId: taskId,
      type: type,
      createdAt: ISO8601DateFormatter().string(from: Date()),
      summary: summary,
      detail: nil,
      approvalId: nil,
      approval: nil,
      result: nil,
      imageBase64: nil
    )
    events.insert(event, at: 0)
  }

  private func resetVoiceState() {
    voiceState = VoiceRuntimeState(
      connected: false,
      muted: true,
      phase: "idle",
      currentAgent: voiceState.currentAgent,
      level: 0
    )
  }

  private func makeActionCallout(for event: BackendEvent) -> OverlayActionCallout {
    switch event.type {
    case "started":
      return OverlayActionCallout(
        label: "Operator",
        text: event.summary ?? "Preparing the operator."
      )
    case "delegated":
      return OverlayActionCallout(
        label: "Agent",
        text: event.summary ?? "Handing the task to a specialist."
      )
    case "screenshot":
      return OverlayActionCallout(
        label: "Action",
        text: "Checking the screen."
      )
    case "failed":
      return OverlayActionCallout(
        label: "Error",
        text: event.summary ?? "The operator hit an error."
      )
    case "tool_started":
      if let summary = event.summary, summary.localizedCaseInsensitiveContains("shell") {
        return OverlayActionCallout(label: "Workbench", text: summary)
      }
      if let summary = event.summary, summary.localizedCaseInsensitiveContains("editing files") {
        return OverlayActionCallout(label: "Workbench", text: summary)
      }
      return OverlayActionCallout(
        label: "Action",
        text: event.summary ?? "Taking action."
      )
    default:
      return OverlayActionCallout(label: "Action", text: "Preparing the operator.")
    }
  }

  private func latestOverlayActionEvent(for taskId: String) -> BackendEvent? {
    if let concreteAction = events.first(where: { event in
      event.taskId == taskId && isConcreteOverlayActionEvent(event)
    }) {
      return concreteAction
    }

    return events.first(where: { event in
      event.taskId == taskId && shouldSurfaceInOverlayActionCallout(event)
    })
  }

  private func shouldSurfaceInOverlayActionCallout(_ event: BackendEvent) -> Bool {
    switch event.type {
    case "started", "delegated", "tool_started", "screenshot", "failed":
      return true
    default:
      return false
    }
  }

  private func isConcreteOverlayActionEvent(_ event: BackendEvent) -> Bool {
    switch event.type {
    case "screenshot":
      return true
    case "tool_started":
      guard let summary = event.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
            !summary.isEmpty else {
        return false
      }
      return !summary.hasPrefix("Calling ")
    default:
      return false
    }
  }

  private func applyRecentBackendEvents(_ recentEvents: [BackendEvent]) {
    let newEvents = recentEvents
      .reversed()
      .filter { event in
        !seenBackendEventIDs.contains(event.id)
      }

    guard !newEvents.isEmpty else {
      return
    }

    for event in newEvents {
      seenBackendEventIDs.insert(event.id)
      logNativeOverlay("Polled backend event \(event.type) for \(event.taskId): \(event.summary ?? "-")")
      handle(event: event)
    }
  }

  private func logNativeOverlay(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    let data = Data(line.utf8)
    if FileManager.default.fileExists(atPath: nativeLogURL.path) {
      if let handle = try? FileHandle(forWritingTo: nativeLogURL) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        return
      }
    }
    try? data.write(to: nativeLogURL, options: .atomic)
  }

  private func syncPhase() {
    if pendingRealtimeApproval != nil || pendingApproval != nil {
      phase = "approvals"
      return
    }

    if !errorMessage.isEmpty {
      phase = "error"
      return
    }

    if !voiceRuntimeErrorMessage.isEmpty && (!voiceState.connected || voiceState.phase == "error") {
      phase = "error"
      return
    }

    if listeningModeActive && !voiceState.connected {
      phase = "listening"
      return
    }

    if voiceState.phase == "connecting" {
      phase = listeningModeActive ? "listening" : "connecting"
      return
    }

    guard voiceState.connected else {
      if activeTaskId != nil {
        phase = "acting"
        return
      }
      phase = "idle"
      return
    }

    switch voiceState.phase {
    case "connecting":
      phase = listeningModeActive ? "listening" : "connecting"
    case "thinking":
      phase = "thinking"
    case "speaking":
      phase = "speaking"
    case "acting":
      phase = "acting"
    case "error":
      phase = "error"
    case "listening":
      phase = !voiceState.muted ? "listening" : "idle"
    default:
      phase = activeTaskId != nil ? "acting" : "idle"
    }
  }
}
