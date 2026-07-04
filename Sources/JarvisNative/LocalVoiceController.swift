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
  private var voiceProcessingEnabled = false

  // STT engine: "apple" = SFSpeechRecognizer (needs macOS Dictation enabled);
  // "parakeet" = local Parakeet-TDT server on 127.0.0.1:4821 (no Dictation).
  private var sttEngine = "apple"
  private let pcmAccumulator = PcmAccumulatorBox()
  private nonisolated static let parakeetURL = URL(string: "http://127.0.0.1:4821/transcribe")!

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

  /// Persistent pipeline log (logs/local-voice.log). NSLog output is
  /// impractical to retrieve from the unified log after the fact, and
  /// diagnosing "it stopped listening" reports needs the exact transition
  /// history from the user's session.
  private nonisolated static let vlogURL = AppIdentity.logsDirectory().appending(path: "local-voice.log")

  nonisolated static func vlog(_ message: String) {
    NSLog("LocalVoice: %@", message)
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    let data = Data(line.utf8)
    if let handle = try? FileHandle(forWritingTo: vlogURL) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      try? data.write(to: vlogURL, options: .atomic)
    }
  }

  var bargeInEnabled = true

  func configure(language: String, sttEngine: String = "apple", bargeIn: Bool = true) {
    self.language = language == "en" ? "en" : "es"
    self.sttEngine = sttEngine == "parakeet" ? "parakeet" : "apple"
    self.bargeInEnabled = bargeIn
  }

  func startListening(continuous: Bool = false, interruptSpeech: Bool = true) async {
    guard !capturing else { return }
    continuousMode = continuous

    if sttEngine == "apple" {
      let status = await Self.requestSpeechAuthorization()
      guard status == .authorized else {
        onError?(
          language == "en"
            ? "Speech recognition permission is required for the local provider. Enable it in System Settings > Privacy & Security > Speech Recognition."
            : "El proveedor local necesita el permiso de Reconocimiento de voz. Actívalo en Ajustes del Sistema > Privacidad y seguridad > Reconocimiento de voz.")
        return
      }
    }

    // Barge-in: pressing the hotkey silences any reply still playing. When
    // resuming capture DURING a reply (hands-free), the speech keeps playing.
    if interruptSpeech, synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
      pendingUtterances = 0
      sentenceBuffer = ""
    }
    if interruptSpeech {
      streamFinished = true
    }

    let usingApple = sttEngine == "apple"
    let locale = Locale(identifier: language == "en" ? "en_US" : "es_ES")
    var request: SFSpeechAudioBufferRecognitionRequest?
    var recognizer: SFSpeechRecognizer?
    if usingApple {
      recognizer = SFSpeechRecognizer(locale: locale)
      guard let appleRecognizer = recognizer, appleRecognizer.isAvailable else {
        onError?("Speech recognition is not available for \(locale.identifier).")
        return
      }
      self.recognizer = appleRecognizer
      let appleRequest = SFSpeechAudioBufferRecognitionRequest()
      appleRequest.shouldReportPartialResults = true
      if appleRecognizer.supportsOnDeviceRecognition {
        appleRequest.requiresOnDeviceRecognition = true
      }
      request = appleRequest
      recognitionRequest = appleRequest
    }
    latestTranscript = ""
    recognitionErrorMessage = ""
    Self.vlog("startListening engine=\(sttEngine) locale=\(locale.identifier) continuous=\(continuous) interruptSpeech=\(interruptSpeech)")

    let inputNode = audioEngine.inputNode
    // Echo cancellation is ONLY needed for barge-in (capturing while Jarvis
    // speaks). The voice-processing unit switches the input to a multichannel
    // AEC format that degrades SFSpeechRecognizer after playback cycles —
    // with barge-in off, keep the plain mic path Apple STT is happiest with.
    if bargeInEnabled != voiceProcessingEnabled {
      if (try? inputNode.setVoiceProcessingEnabled(bargeInEnabled)) != nil {
        voiceProcessingEnabled = bargeInEnabled
        Self.vlog("voice processing (AEC) now \(bargeInEnabled ? "ON" : "OFF") to match barge-in setting")
      } else {
        Self.vlog("WARNING: could not toggle voice processing to \(bargeInEnabled)")
      }
    }
    let format = inputNode.outputFormat(forBus: 0)
    Self.vlog("input format sampleRate=\(format.sampleRate) channels=\(format.channelCount) voiceProcessing=\(voiceProcessingEnabled)")
    guard format.sampleRate > 0 else {
      Self.vlog("ERROR: input format has zero sample rate — no capture possible")
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
    let accumulator = usingApple ? nil : pcmAccumulator
    accumulator?.reset(sampleRate: format.sampleRate)
    let appleRequest = request
    inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in
      // Voice processing (AEC, enabled for barge-in) switches the input to a
      // multichannel format (7 ch on MacBook mic arrays): channel 0 is the
      // processed voice, the rest are reference/beamforming channels.
      // SFSpeechRecognizer fed the raw multichannel buffer fails silently
      // with "No speech detected" — hand it a mono copy of channel 0, the
      // same channel the Parakeet accumulator and the RMS meter read.
      appleRequest?.append(Self.monoChannel0(buffer) ?? buffer)
      accumulator?.append(buffer)
      micLevel.note(rms: Self.bufferRms(buffer))
    }

    do {
      audioEngine.prepare()
      try audioEngine.start()
    } catch {
      Self.vlog("ERROR: audioEngine.start failed: \(error.localizedDescription)")
      onError?("Could not start the microphone: \(error.localizedDescription)")
      return
    }

    capturing = true
    // When resuming capture mid-reply (hands-free barge-in), Jarvis is still
    // speaking — keep the "speaking" phase instead of flashing "listening".
    // The phase advances naturally once the reply's utterances drain.
    if interruptSpeech || (pendingUtterances == 0 && !synthesizer.isSpeaking) {
      onPhaseChange?("listening")
    }
    if continuousMode {
      startSilenceWatch()
    }
    guard usingApple, let recognizer, let request else { return }
    // @Sendable for the same reason as the tap above: the recognizer invokes
    // this on a background speech queue.
    recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
      if let error {
        let message = error.localizedDescription
        Task { @MainActor in
          guard let self else { return }
          // "Canceled"/216 arrive on every normal teardown, and "No speech
          // detected" (1110) just means the capture window held no words —
          // the silence path handles that; treating it as a hard failure
          // tore down hands-free mode after every quiet window.
          if !message.localizedCaseInsensitiveContains("cancel"),
             !message.localizedCaseInsensitiveContains("no speech") {
            self.recognitionErrorMessage = message
            Self.vlog("recognition error: \(message)")
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

  /// Non-async convenience to re-arm hands-free from a sync context (settings
  /// callbacks) without blocking; no-op if already capturing.
  func startListeningIfIdle(continuous: Bool) {
    guard !capturing else { return }
    Task { @MainActor in
      await self.startListening(continuous: continuous)
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
    if sttEngine == "parakeet" {
      onPhaseChange?("thinking")
      if let wav = pcmAccumulator.wavData16k() {
        do {
          latestTranscript = try await Self.transcribeWithParakeet(wav)
        } catch {
          recognitionErrorMessage = error.localizedDescription
          NSLog("LocalVoice: parakeet error: %@", recognitionErrorMessage)
        }
      }
    } else {
      recognitionRequest?.endAudio()
      // Give the recognizer a moment to finalize the tail of the utterance.
      try? await Task.sleep(nanoseconds: 400_000_000)
      recognitionTask?.cancel()
      recognitionTask = nil
      recognitionRequest = nil
    }

    let text = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      let mic = micLevel.snapshot()
      Self.vlog("empty transcript. engine=\(sttEngine) speechDetected=\(mic.speechDetected) recognitionError=\(recognitionErrorMessage.isEmpty ? "none" : recognitionErrorMessage)")
      if continuousMode && recognitionErrorMessage.isEmpty {
        // No hard error: either true silence, or audio that produced no words
        // (echo bleed from the reply, background noise, a cough). Either way,
        // KEEP the hands-free conversation open — tearing it down here left
        // the mic looking on while nothing listened.
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

    Self.vlog("turn committed. engine=\(sttEngine) transcriptChars=\(text.count)")
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
        if continuousMode && bargeInEnabled {
          // Resume capture while the reply plays so the user can barge in;
          // echo cancellation + the raised playback threshold keep Jarvis's
          // own voice from triggering it.
          await startListening(continuous: true, interruptSpeech: false)
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

  /// "Stop" button: cut the reply that is currently playing (and any queued
  /// sentences) but KEEP the conversation — unlike stop(), which tears the
  /// whole pipeline down.
  func interruptPlayback() {
    guard synthesizer.isSpeaking || pendingUtterances > 0 || !streamFinished else {
      Self.vlog("interrupt requested but nothing is playing")
      return
    }
    Self.vlog("interrupt: cutting the current reply")
    synthesizer.stopSpeaking(at: .immediate)
    pendingUtterances = 0
    sentenceBuffer = ""
    streamFinished = true
    micLevel.setPlaybackMode(false)
    if continuousMode && !capturing {
      Task { @MainActor in
        guard self.continuousMode else { return }
        await self.startListening(continuous: true)
      }
    } else {
      onPhaseChange?(capturing ? "listening" : "idle")
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
      micLevel.setPlaybackMode(true)
    }
    pendingUtterances += 1
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = Self.bestVoice(for: language)
    synthesizer.speak(utterance)
  }

  /// Highest-quality installed voice for the language: premium > enhanced >
  /// default. `AVSpeechSynthesisVoice(language:)` alone always returns the
  /// compact voice, which is the robotic-sounding worst tier — if the user has
  /// downloaded an enhanced/premium voice (System Settings > Accessibility >
  /// Spoken Content > System Voice > Manage Voices…), prefer it. Cached until
  /// the system reports a voice install/removal (the user can download a
  /// better voice while Jarvis is running and it should be picked up live).
  private static var cachedVoice: (language: String, voice: AVSpeechSynthesisVoice?)?
  private static let voicesChangedObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
    forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
    object: nil, queue: .main
  ) { _ in
    Task { @MainActor in
      cachedVoice = nil
      NSLog("LocalVoice: installed voices changed; re-selecting TTS voice")
    }
  }

  private static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
    _ = voicesChangedObserver  // arm the invalidation observer on first use
    if let cached = cachedVoice, cached.language == language {
      return cached.voice
    }
    let prefix = language == "en" ? "en" : "es"
    let preferred = language == "en" ? "en-US" : "es-ES"
    let candidates = AVSpeechSynthesisVoice.speechVoices()
      .filter { $0.language.hasPrefix(prefix) }
      // Novelty/eloquence voices (Grandma, Rocko…) are compact-quality; the
      // real ranking is quality tier, then exact-locale match as tiebreak.
      .sorted { a, b in
        if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
        return (a.language == preferred ? 0 : 1) < (b.language == preferred ? 0 : 1)
      }
    let voice = candidates.first { $0.quality != .default }
      ?? AVSpeechSynthesisVoice(language: preferred)
    NSLog("LocalVoice: TTS voice=%@ quality=%d", voice?.name ?? "system default", voice?.quality.rawValue ?? 0)
    cachedVoice = (language, voice)
    return voice
  }

  private func settleIfDone() {
    guard streamFinished, pendingUtterances == 0 else { return }
    micLevel.setPlaybackMode(false)
    if continuousMode && !capturing {
      // Hands-free conversation: resume listening after the reply finishes.
      Self.vlog("reply finished; resuming capture")
      Task { @MainActor in
        // Re-check: a Mute/Stop between scheduling and execution must win —
        // resuming here would silently re-open the mic behind the user.
        guard self.continuousMode else {
          Self.vlog("resume cancelled: continuous mode ended (mute/stop)")
          return
        }
        await self.startListening(continuous: true)
      }
    } else if continuousMode && capturing {
      // Capture already resumed during the reply (barge-in support). The
      // user did NOT barge in, so anything the mic flagged as speech during
      // playback was echo bleed from Jarvis's own reply — clear it, or the
      // silence watcher instantly commits a garbage turn (stale
      // speechDetected with lastSpeechAt > 1.6 s ago) and the accumulated
      // echo audio poisons the next transcription.
      Self.vlog("reply finished; capture already live (barge-in armed) — clearing echo-tainted mic state")
      micLevel.reset()
      pcmAccumulator.reset(sampleRate: pcmAccumulator.currentSampleRate())
      onPhaseChange?("listening")
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

        // Barge-in: the user starts talking over the reply → cut the speech
        // and keep listening; the silence rule below then commits their turn.
        if self.pendingUtterances > 0 || self.synthesizer.isSpeaking {
          if snapshot.speechDetected, Date().timeIntervalSince(snapshot.lastSpeechAt) < 0.5 {
            Self.vlog("barge-in: user spoke over the reply; cutting speech")
            self.synthesizer.stopSpeaking(at: .immediate)
            self.pendingUtterances = 0
            self.micLevel.setPlaybackMode(false)
            self.onPhaseChange?("listening")
          }
          return
        }

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

  /// Mono copy of channel 0 for consumers that can't handle the AEC unit's
  /// multichannel format. Returns nil for already-mono or non-float buffers
  /// (caller falls back to the original buffer).
  private nonisolated static func monoChannel0(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard buffer.format.channelCount > 1,
          let source = buffer.floatChannelData?[0],
          let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
            channels: 1, interleaved: false),
          let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
          let target = mono.floatChannelData?[0]
    else { return nil }
    mono.frameLength = buffer.frameLength
    target.update(from: source, count: Int(buffer.frameLength))
    return mono
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
    // Read the agent's own answer (trimmed for speech) so the user hears WHAT
    // it said, not just that it finished.
    let summary = String(status.summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(220))
    var announcement: String?
    if state == "needs_user" {
      announcement = english ? "\(name) needs your approval or input." : "\(name) necesita tu aprobación o intervención."
    } else if state == "offline" {
      announcement = english ? "\(name) is no longer available." : "\(name) dejó de estar disponible."
    } else if state == "idle" && monitorSawWorking {
      announcement =
        english
        ? "\(name) finished." + (summary.isEmpty ? "" : " Summary: \(summary)")
        : "\(name) terminó." + (summary.isEmpty ? "" : " Resumen: \(summary)")
    }
    guard let announcement else { return }

    onAssistantReply?(announcement)
    speakChunk(announcement)
    stopAgentMonitor()
  }

  /// nonisolated: the TCC authorization callback arrives on a background
  /// queue; a MainActor-isolated continuation closure would trip Swift 6's
  /// executor check and crash the app right as the user accepts the prompt.
  /// Fire-and-forget warm-up so the first real utterance doesn't pay any
  /// cold-start cost: a short silent clip exercises the whole Parakeet path.
  nonisolated static func warmUpParakeet() {
    Task.detached(priority: .background) {
      // 0.2 s of silence (16 kHz mono 16-bit → 6400 bytes) exercises the path.
      let silence = makeWav16k(pcm16: Data(count: 6400))
      _ = try? await transcribeWithParakeet(silence)
    }
  }

  /// Sends a 16 kHz mono WAV to the local Parakeet server and returns the text.
  private nonisolated static func transcribeWithParakeet(_ wav: Data) async throws -> String {
    var request = URLRequest(url: parakeetURL)
    request.httpMethod = "POST"
    request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
    request.httpBody = wav
    request.timeoutInterval = 30
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      struct Reply: Codable {
        var text: String?
        var error: String?
      }
      let reply = try? JSONDecoder().decode(Reply.self, from: data)
      if status == 200, let text = reply?.text {
        return text
      }
      if status == 503 {
        throw NSError(
          domain: "LocalVoice", code: 503,
          userInfo: [NSLocalizedDescriptionKey: "Parakeet is still loading its model — try again in a few seconds."])
      }
      throw NSError(
        domain: "LocalVoice", code: status,
        userInfo: [NSLocalizedDescriptionKey: reply?.error ?? "Parakeet server returned HTTP \(status)."])
    } catch let error as NSError where error.domain == NSURLErrorDomain {
      throw NSError(
        domain: "LocalVoice", code: error.code,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Parakeet server is not running on 127.0.0.1:4821. Run scripts/setup-parakeet.sh and load the com.jarvis.parakeet LaunchAgent."
        ])
    }
  }

  private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status)
      }
    }
  }
}

/// Wraps 16 kHz mono 16-bit PCM samples in a WAV container. Shared by the
/// Parakeet warm-up clip and the live accumulator so the RIFF header is built
/// in exactly one place.
func makeWav16k(pcm16: Data) -> Data {
  var data = Data(capacity: 44 + pcm16.count)
  let byteCount = UInt32(pcm16.count)
  func appendLE(_ value: UInt32) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
  }
  func appendLE16(_ value: UInt16) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
  }
  data.append(contentsOf: Array("RIFF".utf8))
  appendLE(36 + byteCount)
  data.append(contentsOf: Array("WAVE".utf8))
  data.append(contentsOf: Array("fmt ".utf8))
  appendLE(16)
  appendLE16(1)       // PCM
  appendLE16(1)       // mono
  appendLE(16_000)    // sample rate
  appendLE(32_000)    // byte rate = 16000 * 1 channel * 2 bytes
  appendLE16(2)       // block align
  appendLE16(16)      // bits per sample
  data.append(contentsOf: Array("data".utf8))
  appendLE(byteCount)
  data.append(pcm16)
  return data
}

/// Thread-safe PCM accumulator for the Parakeet path: the realtime audio tap
/// appends float samples; on turn commit they are resampled to 16 kHz mono
/// Int16 and wrapped in a WAV container.
private final class PcmAccumulatorBox: @unchecked Sendable {
  private let lock = NSLock()
  private var samples: [Float] = []
  private var sampleRate: Double = 48_000
  /// ~2 minutes at 48 kHz — enough for any voice command.
  private let maxSamples = 48_000 * 120

  func reset(sampleRate: Double) {
    lock.lock()
    samples.removeAll(keepingCapacity: true)
    self.sampleRate = sampleRate
    lock.unlock()
  }

  func currentSampleRate() -> Double {
    lock.lock()
    defer { lock.unlock() }
    return sampleRate
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
    lock.lock()
    if samples.count < maxSamples {
      samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }
    lock.unlock()
  }

  func wavData16k() -> Data? {
    lock.lock()
    let source = samples
    let rate = sampleRate
    lock.unlock()
    guard !source.isEmpty, rate > 0 else { return nil }

    let targetRate = 16_000.0
    let ratio = rate / targetRate
    let outputCount = Int(Double(source.count) / ratio)
    guard outputCount > 0 else { return nil }

    var pcm16 = [Int16](repeating: 0, count: outputCount)
    for i in 0 ..< outputCount {
      let position = Double(i) * ratio
      let index = Int(position)
      let fraction = Float(position - Double(index))
      let a = source[min(index, source.count - 1)]
      let b = source[min(index + 1, source.count - 1)]
      let sample = a + (b - a) * fraction
      pcm16[i] = Int16(max(-1.0, min(1.0, sample)) * 32767.0)
    }

    let pcmData = pcm16.withUnsafeBytes { Data($0) }
    return makeWav16k(pcm16: pcmData)
  }
}

/// Thread-safe mic level tracker shared between the realtime audio tap and
/// the MainActor silence watcher.
private final class MicLevelBox: @unchecked Sendable {
  private let lock = NSLock()
  private var speech = false
  private var lastSpeech = Date.distantPast
  private var playbackMode = false

  func reset() {
    lock.lock()
    speech = false
    lastSpeech = .distantPast
    lock.unlock()
  }

  /// While the reply is playing, require a much louder signal to count as
  /// user speech — echo cancellation is good but not perfect.
  func setPlaybackMode(_ active: Bool) {
    lock.lock()
    playbackMode = active
    lock.unlock()
  }

  func note(rms: Float) {
    lock.lock()
    // Voice-processing (echo cancellation) noticeably lowers input gain, so
    // these thresholds are calibrated for the processed signal.
    let threshold: Float = playbackMode ? 0.035 : 0.008
    if rms > threshold {
      speech = true
      lastSpeech = Date()
    }
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
