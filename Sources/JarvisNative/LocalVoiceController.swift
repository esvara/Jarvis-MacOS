import AVFoundation
import Speech

/// v3 "local" voice provider: fully on-device speech loop. Apple's
/// SFSpeechRecognizer transcribes the user (on-device when the locale
/// supports it), the sidecar runs the agent turn against a local Ollama
/// model, and AVSpeechSynthesizer speaks the reply — sentence by sentence
/// while the model is still generating. Push-to-talk only.
@MainActor
final class LocalVoiceController: NSObject {
  var onPhaseChange: ((String) -> Void)?
  var onUserTranscript: ((String) -> Void)?
  var onAssistantReply: ((String) -> Void)?
  var onError: ((String) -> Void)?

  private let client: SidecarClient
  private let audioEngine = AVAudioEngine()
  private let synthesizer = AVSpeechSynthesizer()
  private var recognizer: SFSpeechRecognizer?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var latestTranscript = ""
  private var recognitionErrorMessage = ""
  private var capturing = false
  private var language = "es"

  // Sentence-streaming TTS state
  private var sentenceBuffer = ""
  private var pendingUtterances = 0
  private var streamFinished = true

  // Continuous (hands-free) mode: auto-commit after trailing silence and
  // resume listening once the reply finishes. Push-to-talk keeps this off.
  private var continuousMode = false
  private var silenceTimer: Timer?
  private let micLevel = MicLevelBox()

  // Post-delegation monitor state
  private var monitorTimer: Timer?
  private var monitorAgent: String?
  private var monitorStartedAt = Date.distantPast
  private var monitorSawWorking = false
  private var monitorLastState = ""

  init(client: SidecarClient) {
    self.client = client
    super.init()
    synthesizer.delegate = self
  }

  func configure(language: String) {
    self.language = language == "en" ? "en" : "es"
  }

  func startListening(continuous: Bool = false) async {
    guard !capturing else { return }
    continuousMode = continuous

    let status = await Self.requestSpeechAuthorization()
    guard status == .authorized else {
      onError?(
        language == "en"
          ? "Speech recognition permission is required for the local provider. Enable it in System Settings > Privacy & Security > Speech Recognition."
          : "El proveedor local necesita el permiso de Reconocimiento de voz. Actívalo en Ajustes del Sistema > Privacidad y seguridad > Reconocimiento de voz.")
      return
    }

    // Barge-in: pressing the hotkey silences any reply still playing.
    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
    }
    pendingUtterances = 0
    sentenceBuffer = ""
    streamFinished = true

    let locale = Locale(identifier: language == "en" ? "en_US" : "es_ES")
    let recognizer = SFSpeechRecognizer(locale: locale)
    guard let recognizer, recognizer.isAvailable else {
      onError?("Speech recognition is not available for \(locale.identifier).")
      return
    }
    self.recognizer = recognizer

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    if recognizer.supportsOnDeviceRecognition {
      request.requiresOnDeviceRecognition = true
    }
    recognitionRequest = request
    latestTranscript = ""
    recognitionErrorMessage = ""
    NSLog(
      "LocalVoice: startListening locale=%@ onDevice=%d continuous=%d",
      locale.identifier, recognizer.supportsOnDeviceRecognition ? 1 : 0, continuous ? 1 : 0)

    let inputNode = audioEngine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0 else {
      onError?(
        language == "en"
          ? "No audio input device is available."
          : "No hay un dispositivo de entrada de audio disponible.")
      return
    }
    inputNode.removeTap(onBus: 0)
    // @Sendable: the tap fires on the audio realtime queue; a closure formed
    // in this @MainActor context would otherwise inherit main-actor isolation
    // and trip Swift 6's executor check (dispatch_assert_queue_fail).
    let micLevel = self.micLevel
    micLevel.reset()
    inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in
      request.append(buffer)
      micLevel.note(rms: Self.bufferRms(buffer))
    }

    do {
      audioEngine.prepare()
      try audioEngine.start()
    } catch {
      onError?("Could not start the microphone: \(error.localizedDescription)")
      return
    }

    capturing = true
    onPhaseChange?("listening")
    if continuousMode {
      startSilenceWatch()
    }
    // @Sendable for the same reason as the tap above: the recognizer invokes
    // this on a background speech queue.
    recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
      if let error {
        let message = error.localizedDescription
        Task { @MainActor in
          guard let self else { return }
          // "Canceled"/216 arrive on every normal teardown; keep real failures.
          if !message.localizedCaseInsensitiveContains("cancel") {
            self.recognitionErrorMessage = message
            NSLog("LocalVoice: recognition error: %@", message)
          }
        }
      }
      guard let result else { return }
      let text = result.bestTranscription.formattedString
      Task { @MainActor in
        self?.latestTranscript = text
      }
    }
  }

  func stopListeningAndRespond(endContinuous: Bool = false) async {
    guard capturing else { return }
    capturing = false
    if endContinuous {
      continuousMode = false
    }
    stopSilenceWatch()

    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    recognitionRequest?.endAudio()
    // Give the recognizer a moment to finalize the tail of the utterance.
    try? await Task.sleep(nanoseconds: 400_000_000)
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionRequest = nil

    let text = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      let mic = micLevel.snapshot()
      NSLog(
        "LocalVoice: empty transcript. speechDetected=%d recognitionError=%@",
        mic.speechDetected ? 1 : 0, recognitionErrorMessage)
      if continuousMode && recognitionErrorMessage.isEmpty && !mic.speechDetected {
        // True silence; keep the hands-free conversation open.
        await startListening(continuous: true)
        return
      }
      continuousMode = false
      let detail: String
      if !recognitionErrorMessage.isEmpty {
        detail = language == "en"
          ? "Speech recognition failed: \(recognitionErrorMessage) If Spanish dictation is not downloaded, enable it in System Settings > Keyboard > Dictation."
          : "El reconocimiento de voz falló: \(recognitionErrorMessage) Si el dictado en español no está descargado, actívalo en Ajustes del Sistema > Teclado > Dictado."
      } else if mic.speechDetected {
        detail = language == "en"
          ? "The microphone captured audio but no words were recognized. Try again closer to the mic."
          : "El micrófono captó audio pero no se reconocieron palabras. Intenta de nuevo más cerca del micrófono."
      } else {
        detail = language == "en"
          ? "The microphone captured no audio — check the input device and volume."
          : "El micrófono no captó audio — revisa el dispositivo de entrada y su volumen."
      }
      onError?(detail)
      onPhaseChange?("idle")
      return
    }

    onUserTranscript?(text)
    onPhaseChange?("thinking")
    sentenceBuffer = ""
    streamFinished = false
    do {
      let result = try await client.localVoiceTurnStream(text: text, language: language) { [weak self] delta in
        Task { @MainActor in
          self?.consumeDelta(delta)
        }
      }
      streamFinished = true
      flushSentenceBuffer()
      if result.ok, let reply = result.reply, !reply.isEmpty {
        onAssistantReply?(reply)
        if result.delegatedAgent != nil {
          startAgentMonitor(result.delegatedAgent ?? "codex")
        }
        settleIfDone()
      } else {
        continuousMode = false
        onError?(result.error ?? "The local voice agent returned no reply.")
        onPhaseChange?("idle")
      }
    } catch {
      streamFinished = true
      continuousMode = false
      onError?(error.localizedDescription)
      onPhaseChange?("idle")
    }
  }

  func stop() {
    stopAgentMonitor()
    stopSilenceWatch()
    continuousMode = false
    if capturing {
      capturing = false
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
      recognitionTask?.cancel()
      recognitionTask = nil
      recognitionRequest = nil
    }
    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
    }
    pendingUtterances = 0
    onPhaseChange?("idle")
  }

  // MARK: - Sentence-streamed speech

  /// Accumulates deltas and speaks complete sentences as soon as they close,
  /// so the reply starts ~1 s after generation begins instead of at the end.
  private func consumeDelta(_ delta: String) {
    sentenceBuffer += delta
    while let range = sentenceBuffer.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?…\n")) {
      let sentence = String(sentenceBuffer[..<range.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
      sentenceBuffer = String(sentenceBuffer[range.upperBound...])
      if !sentence.isEmpty {
        speakChunk(sentence)
      }
    }
  }

  private func flushSentenceBuffer() {
    let remainder = sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
    sentenceBuffer = ""
    if !remainder.isEmpty {
      speakChunk(remainder)
    }
  }

  private func speakChunk(_ text: String) {
    if pendingUtterances == 0 {
      onPhaseChange?("speaking")
    }
    pendingUtterances += 1
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: language == "en" ? "en-US" : "es-ES")
    synthesizer.speak(utterance)
  }

  private func settleIfDone() {
    guard streamFinished, pendingUtterances == 0 else { return }
    if continuousMode && !capturing {
      // Hands-free conversation: resume listening after the reply finishes.
      Task { @MainActor in
        await self.startListening(continuous: true)
      }
    } else {
      onPhaseChange?("idle")
    }
  }

  // MARK: - Silence auto-commit (hands-free mode)

  /// After the user has spoken, ~1.6 s of trailing silence ends the turn
  /// automatically — the button behaves like a conversation, not a walkie.
  private func startSilenceWatch() {
    stopSilenceWatch()
    silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.capturing, self.continuousMode else { return }
        let snapshot = self.micLevel.snapshot()
        if snapshot.speechDetected, Date().timeIntervalSince(snapshot.lastSpeechAt) > 1.6 {
          await self.stopListeningAndRespond()
        }
      }
    }
  }

  private func stopSilenceWatch() {
    silenceTimer?.invalidate()
    silenceTimer = nil
  }

  private nonisolated static func bufferRms(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
    var sum: Float = 0
    for i in 0 ..< Int(buffer.frameLength) {
      sum += data[i] * data[i]
    }
    return (sum / Float(buffer.frameLength)).squareRoot()
  }

  // MARK: - Post-delegation monitor

  /// Mirrors the cloud runtime's proactive monitor: after a delegation is
  /// delivered, poll the agent every 30 s (up to 30 min) and announce
  /// completion, blockers, or needed approvals out loud.
  private func startAgentMonitor(_ agent: String) {
    stopAgentMonitor()
    monitorAgent = agent
    monitorStartedAt = Date()
    monitorSawWorking = false
    monitorLastState = ""
    monitorTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      Task { @MainActor in
        await self?.pollAgentMonitor()
      }
    }
  }

  private func stopAgentMonitor() {
    monitorTimer?.invalidate()
    monitorTimer = nil
    monitorAgent = nil
  }

  private func pollAgentMonitor() async {
    guard let agent = monitorAgent else { return }
    if Date().timeIntervalSince(monitorStartedAt) > 30 * 60 {
      stopAgentMonitor()
      return
    }
    // Don't talk over the user or a reply in flight.
    guard !capturing, pendingUtterances == 0, streamFinished else { return }

    guard let status = try? await client.codexPmStatus(agent: agent, quiet: true) else { return }
    let state = status.currentState
    if state == "working" {
      monitorSawWorking = true
    }
    if state == monitorLastState {
      return
    }
    monitorLastState = state

    let name = agent == "claude" ? "Claude" : "Codex"
    let english = language == "en"
    var announcement: String?
    if state == "needs_user" {
      announcement = english ? "\(name) needs your approval or input." : "\(name) necesita tu aprobación o intervención."
    } else if state == "offline" {
      announcement = english ? "\(name) is no longer available." : "\(name) dejó de estar disponible."
    } else if state == "idle" && monitorSawWorking {
      announcement = english ? "\(name) appears to have finished the task." : "\(name) parece haber terminado la tarea."
    }
    guard let announcement else { return }

    onAssistantReply?(announcement)
    speakChunk(announcement)
    stopAgentMonitor()
  }

  /// nonisolated: the TCC authorization callback arrives on a background
  /// queue; a MainActor-isolated continuation closure would trip Swift 6's
  /// executor check and crash the app right as the user accepts the prompt.
  private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status)
      }
    }
  }
}

/// Thread-safe mic level tracker shared between the realtime audio tap and
/// the MainActor silence watcher.
private final class MicLevelBox: @unchecked Sendable {
  private let lock = NSLock()
  private var speech = false
  private var lastSpeech = Date.distantPast

  func reset() {
    lock.lock()
    speech = false
    lastSpeech = .distantPast
    lock.unlock()
  }

  func note(rms: Float) {
    guard rms > 0.015 else { return }
    lock.lock()
    speech = true
    lastSpeech = Date()
    lock.unlock()
  }

  func snapshot() -> (speechDetected: Bool, lastSpeechAt: Date) {
    lock.lock()
    defer { lock.unlock() }
    return (speech, lastSpeech)
  }
}

extension LocalVoiceController: AVSpeechSynthesizerDelegate {
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor in
      self.pendingUtterances = max(0, self.pendingUtterances - 1)
      self.settleIfDone()
    }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    Task { @MainActor in
      self.pendingUtterances = max(0, self.pendingUtterances - 1)
      self.settleIfDone()
    }
  }
}
