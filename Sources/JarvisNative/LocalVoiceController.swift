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
  private var capturing = false
  private var language = "es"

  // Sentence-streaming TTS state
  private var sentenceBuffer = ""
  private var pendingUtterances = 0
  private var streamFinished = true

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

  func startListening() async {
    guard !capturing else { return }

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

    let inputNode = audioEngine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    inputNode.removeTap(onBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
      request.append(buffer)
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
    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
      guard let result else { return }
      let text = result.bestTranscription.formattedString
      Task { @MainActor in
        self?.latestTranscript = text
      }
    }
  }

  func stopListeningAndRespond() async {
    guard capturing else { return }
    capturing = false

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
        onError?(result.error ?? "The local voice agent returned no reply.")
        onPhaseChange?("idle")
      }
    } catch {
      streamFinished = true
      onError?(error.localizedDescription)
      onPhaseChange?("idle")
    }
  }

  func stop() {
    stopAgentMonitor()
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
    if streamFinished && pendingUtterances == 0 {
      onPhaseChange?("idle")
    }
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

  private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status)
      }
    }
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
