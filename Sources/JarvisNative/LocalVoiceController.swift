import AVFoundation
import Speech

/// v3 "local" voice provider: fully on-device speech loop. Apple's
/// SFSpeechRecognizer transcribes the user (on-device when the locale
/// supports it), the sidecar runs the agent turn against a local Ollama
/// model, and AVSpeechSynthesizer speaks the reply. Push-to-talk only.
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

    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
    }

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
    do {
      let result = try await client.localVoiceTurn(text: text, language: language)
      if result.ok, let reply = result.reply, !reply.isEmpty {
        onAssistantReply?(reply)
        speak(reply)
      } else {
        onError?(result.error ?? "The local voice agent returned no reply.")
        onPhaseChange?("idle")
      }
    } catch {
      onError?(error.localizedDescription)
      onPhaseChange?("idle")
    }
  }

  func stop() {
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
    onPhaseChange?("idle")
  }

  private func speak(_ text: String) {
    onPhaseChange?("speaking")
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: language == "en" ? "en-US" : "es-ES")
    synthesizer.speak(utterance)
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
      self.onPhaseChange?("idle")
    }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    Task { @MainActor in
      self.onPhaseChange?("idle")
    }
  }
}
