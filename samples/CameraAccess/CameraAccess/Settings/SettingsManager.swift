import Foundation

/// Which action-agent backend the app talks to. Both speak the same protocol;
/// only the endpoint and token differ.
/// Order matters: `allCases` drives the picker, and the first segment reads as
/// the primary option. Cloud leads because it is the default.
enum AgentBackend: String, CaseIterable {
  case cloud = "Cloud"
  case selfHosted = "Self-hosted"
}


/// Which model answers. All three are DIRECT backends (see DirectAIBackend.swift): the phone
/// talks to the endpoint itself, or to nothing at all in the local model's case.
///
/// OpenAI and Gemini used to sit here too, routed through LiveKit and a hosted agent worker.
/// They are gone: reaching them needed a gateway account this app's user does not have and will
/// not get, so every one of their screens could only ever report a failure, and the whole
/// LiveKit/agent/gateway stack was dead weight in the binary. The removal took the LiveKit SDK,
/// the call screen, the gateway settings, Connected Apps and Recent Tasks with it.
enum IntelligenceEngine: String, CaseIterable {
  case gigachat = "gigachat"
  case yandexgpt = "yandexgpt"
  case localMLX = "localMLX"

  static let defaultsKey = "intelligenceEngine"

  var label: String {
    switch self {
    case .gigachat: return "GigaChat"
    case .yandexgpt: return "YandexGPT"
    case .localMLX: return "Local (FastVLM)"
    }
  }
}

/// Where video comes from. The app is a vision assistant first -- it opens
/// looking at the world through the phone -- and glasses are one capture
/// source, selected here, rather than a mode the user must decide about at
/// launch. Raw values are stored in UserDefaults under `captureSource`, which
/// views also observe via @AppStorage so a change applies without a relaunch.
enum CaptureSource: String, CaseIterable {
  case iPhoneCamera = "iphone"
  case glasses = "glasses"
  /// Voice only -- no camera track published at all (LiveKitSession.start() skips camera setup
  /// entirely, the same way it already degrades to voice-only on a camera failure). For when you
  /// just want to talk, with no video overhead or camera permission needed.
  case audioOnly = "audio"

  static let defaultsKey = "captureSource"

  var label: String {
    switch self {
    case .iPhoneCamera: return "iPhone Camera"
    case .glasses: return "Glasses"
    case .audioOnly: return "Audio Only"
    }
  }
}

final class SettingsManager {
  static let shared = SettingsManager()

  private let defaults = UserDefaults.standard

  private enum Key: String {
    case geminiAPIKey
    case agentBackend
    case openClawHost
    case openClawPort
    case openClawHookToken
    case openClawGatewayToken
    case cloudGatewayURL
    case cloudGatewayToken
    case accountEmail
    case accountStatus
    case geminiSystemPrompt
    case speakerOutputEnabled
    case videoStreamingEnabled
    case proactiveNotificationsEnabled
    case gigaChatAuthKey
    case gigaChatVisionModel
    case gigaChatTextModel
    case gigaChatSystemPrompt
    case yandexGPTApiKey
    case yandexGPTFolderId
  }

  private init() {}

  // MARK: - Gemini

  var geminiAPIKey: String {
    get { defaults.string(forKey: Key.geminiAPIKey.rawValue) ?? Secrets.geminiAPIKey }
    set { defaults.set(newValue, forKey: Key.geminiAPIKey.rawValue) }
  }

  var geminiSystemPrompt: String {
    get { defaults.string(forKey: Key.geminiSystemPrompt.rawValue) ?? "" }
    set { defaults.set(newValue, forKey: Key.geminiSystemPrompt.rawValue) }
  }

  // MARK: - OpenClaw

  var openClawHost: String {
    get { defaults.string(forKey: Key.openClawHost.rawValue) ?? Secrets.openClawHost }
    set { defaults.set(newValue, forKey: Key.openClawHost.rawValue) }
  }

  var openClawPort: Int {
    get {
      let stored = defaults.integer(forKey: Key.openClawPort.rawValue)
      return stored != 0 ? stored : Secrets.openClawPort
    }
    set { defaults.set(newValue, forKey: Key.openClawPort.rawValue) }
  }

  var openClawHookToken: String {
    get { defaults.string(forKey: Key.openClawHookToken.rawValue) ?? Secrets.openClawHookToken }
    set { defaults.set(newValue, forKey: Key.openClawHookToken.rawValue) }
  }

  var openClawGatewayToken: String {
    get { defaults.string(forKey: Key.openClawGatewayToken.rawValue) ?? Secrets.openClawGatewayToken }
    set { defaults.set(newValue, forKey: Key.openClawGatewayToken.rawValue) }
  }

  // MARK: - Agent backend selection

  var intelligenceEngine: IntelligenceEngine {
    get {
      guard let raw = defaults.string(forKey: IntelligenceEngine.defaultsKey),
            let engine = IntelligenceEngine(rawValue: raw) else { return .gigachat }
      return engine
    }
    set { defaults.set(newValue.rawValue, forKey: IntelligenceEngine.defaultsKey) }
  }

  var captureSource: CaptureSource {
    get {
      guard let raw = defaults.string(forKey: CaptureSource.defaultsKey),
            let source = CaptureSource(rawValue: raw) else { return .iPhoneCamera }
      return source
    }
    set { defaults.set(newValue.rawValue, forKey: CaptureSource.defaultsKey) }
  }

  static let showCaptionsKey = "showCaptions"

  var showCaptions: Bool {
    get { defaults.object(forKey: Self.showCaptionsKey) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Self.showCaptionsKey) }
  }

  /// Dictation language for the Ask screen's mic, as a locale identifier ("ru-RU"). Empty means
  /// "follow the phone". Needed as an explicit choice because guessing it from the app's own
  /// locale is wrong: this app ships English strings only, so `Locale.current` reports en-US even
  /// on a Russian phone, and dictation then transcribed Russian speech into English words.
  static let speechLocaleKey = "speechLocaleIdentifier"

  var speechLocaleIdentifier: String {
    get { defaults.string(forKey: Self.speechLocaleKey) ?? "" }
    set { defaults.set(newValue, forKey: Self.speechLocaleKey) }
  }

  /// Cloud by default: the hosted gateway needs nothing installed and keeps
  /// working with the phone away from home, which self-hosting cannot do.
  var agentBackend: AgentBackend {
    get {
      guard let raw = defaults.string(forKey: Key.agentBackend.rawValue),
            let backend = AgentBackend(rawValue: raw) else { return .cloud }
      return backend
    }
    set { defaults.set(newValue.rawValue, forKey: Key.agentBackend.rawValue) }
  }

  /// Full base URL of the hosted gateway, scheme included (e.g. "https://gw.example.com" or "http://1.2.3.4:8788").
  var cloudGatewayURL: String {
    get { defaults.string(forKey: Key.cloudGatewayURL.rawValue) ?? Secrets.cloudGatewayURL }
    set { defaults.set(newValue, forKey: Key.cloudGatewayURL.rawValue) }
  }

  var cloudGatewayToken: String {
    get { defaults.string(forKey: Key.cloudGatewayToken.rawValue) ?? Secrets.cloudGatewayToken }
    set { defaults.set(newValue, forKey: Key.cloudGatewayToken.rawValue) }
  }

  // MARK: - Account (Google sign-in)

  /// Email of the Google account that created this app's gateway credential.
  var accountEmail: String? {
    get { defaults.string(forKey: Key.accountEmail.rawValue) }
    set { defaults.set(newValue, forKey: Key.accountEmail.rawValue) }
  }

  /// approved | pending | revoked, as last reported by the gateway.
  var accountStatus: String? {
    get { defaults.string(forKey: Key.accountStatus.rawValue) }
    set { defaults.set(newValue, forKey: Key.accountStatus.rawValue) }
  }

  // MARK: - Audio

  var speakerOutputEnabled: Bool {
    get { defaults.bool(forKey: Key.speakerOutputEnabled.rawValue) }
    set { defaults.set(newValue, forKey: Key.speakerOutputEnabled.rawValue) }
  }

  // MARK: - Video

  var videoStreamingEnabled: Bool {
    get { defaults.object(forKey: Key.videoStreamingEnabled.rawValue) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.videoStreamingEnabled.rawValue) }
  }

  // MARK: - Notifications

  var proactiveNotificationsEnabled: Bool {
    get { defaults.object(forKey: Key.proactiveNotificationsEnabled.rawValue) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.proactiveNotificationsEnabled.rawValue) }
  }

  // MARK: - GigaChat (Sber)

  var gigaChatAuthKey: String {
    get { defaults.string(forKey: Key.gigaChatAuthKey.rawValue) ?? "" }
    set { defaults.set(newValue, forKey: Key.gigaChatAuthKey.rawValue) }
  }

  var gigaChatVisionModel: String {
    get { defaults.string(forKey: Key.gigaChatVisionModel.rawValue) ?? "GigaChat-2-Max" }
    set { defaults.set(newValue, forKey: Key.gigaChatVisionModel.rawValue) }
  }

  var gigaChatTextModel: String {
    get { defaults.string(forKey: Key.gigaChatTextModel.rawValue) ?? "GigaChat-2-Pro" }
    set { defaults.set(newValue, forKey: Key.gigaChatTextModel.rawValue) }
  }

  var gigaChatSystemPrompt: String {
    get { defaults.string(forKey: Key.gigaChatSystemPrompt.rawValue) ?? "" }
    set { defaults.set(newValue, forKey: Key.gigaChatSystemPrompt.rawValue) }
  }

  // MARK: - YandexGPT (Yandex Cloud)

  var yandexGPTApiKey: String {
    get { defaults.string(forKey: Key.yandexGPTApiKey.rawValue) ?? "" }
    set { defaults.set(newValue, forKey: Key.yandexGPTApiKey.rawValue) }
  }

  var yandexGPTFolderId: String {
    get { defaults.string(forKey: Key.yandexGPTFolderId.rawValue) ?? "" }
    set { defaults.set(newValue, forKey: Key.yandexGPTFolderId.rawValue) }
  }

  // MARK: - Reset

  func resetAll() {
    for key in [Key.geminiAPIKey, .geminiSystemPrompt, .agentBackend, .openClawHost, .openClawPort,
                .openClawHookToken, .openClawGatewayToken, .cloudGatewayURL, .cloudGatewayToken,
                .accountEmail, .accountStatus,
                .speakerOutputEnabled, .videoStreamingEnabled,
                .proactiveNotificationsEnabled,
                .gigaChatAuthKey, .gigaChatVisionModel, .gigaChatTextModel, .gigaChatSystemPrompt,
                .yandexGPTApiKey, .yandexGPTFolderId] {
      defaults.removeObject(forKey: key.rawValue)
    }
  }
}
