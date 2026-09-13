import Speech
import SwiftUI

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  private let settings = SettingsManager.shared

  @State private var showResetConfirmation = false
  // Applies immediately rather than on Save: the root view observes the same
  // key and swaps the capture pipeline live.
  @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.iPhoneCamera.rawValue
  @AppStorage(IntelligenceEngine.defaultsKey) private var intelligenceRaw = IntelligenceEngine.gigachat.rawValue
  @AppStorage(SettingsManager.speechLocaleKey) private var speechLocaleRaw = ""

  private var cameraFooter: String {
    switch CaptureSource(rawValue: captureSourceRaw) ?? .iPhoneCamera {
    case .glasses: return "Streams from your Meta glasses. Connecting them happens on the main screen."
    case .iPhoneCamera: return "Uses this phone's camera. The app opens straight into it, with voice ready."
    case .audioOnly: return "Voice only, no camera at all -- lowest overhead, quickest to start."
    }
  }

  /// Languages this phone can actually dictate in, alphabetical. Taken from the Speech framework
  /// rather than hardcoded, so a language pack the user installs later simply shows up.
  private static let dictationLocales: [Locale] = {
    SFSpeechRecognizer.supportedLocales()
      .sorted { displayName(for: $0) < displayName(for: $1) }
  }()

  private static func displayName(for locale: Locale) -> String {
    Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
  }

  /// What "Follow phone" resolves to right now. Worth spelling out: it is the phone's own language
  /// setting, NOT the language this app's interface happens to be in.
  private var systemSpeechLanguageName: String {
    let identifier = Locale.preferredLanguages.first ?? Locale.current.identifier
    return Self.displayName(for: Locale(identifier: identifier))
  }

  private var speechFooter: String {
    "Language the mic button on the Ask screen listens for. The app's interface is English, so "
      + "leaving this to the app alone made it listen in English on a Russian phone."
  }

  private var intelligenceFooter: String {
    switch IntelligenceEngine(rawValue: intelligenceRaw) ?? .gigachat {
    case .gigachat: return "Sber's GigaChat, answered straight from this phone. Configure the key under GigaChat below."
    case .yandexgpt: return "Yandex Cloud's YandexGPT, answered straight from this phone. Configure the key under YandexGPT below."
    case .localMLX: return "Runs fully on-device via Apple MLX — no account, no network. Download the model under Local Model below first."
    }
  }

  var body: some View {
    NavigationView {
      Form {
        Section(header: Text("Camera"), footer: Text(cameraFooter)) {
          Picker("Source", selection: $captureSourceRaw) {
            ForEach(CaptureSource.allCases, id: \.rawValue) { source in
              Text(source.label).tag(source.rawValue)
            }
          }
          .pickerStyle(.segmented)
        }

        Section(header: Text("Intelligence"), footer: Text(intelligenceFooter)) {
          Picker("Model", selection: $intelligenceRaw) {
            ForEach(IntelligenceEngine.allCases, id: \.rawValue) { engine in
              Text(engine.label).tag(engine.rawValue)
            }
          }
          .pickerStyle(.menu)
        }

        Section(header: Text("Voice input"), footer: Text(speechFooter)) {
          Picker("Language", selection: $speechLocaleRaw) {
            Text("Follow phone (\(systemSpeechLanguageName))").tag("")
            ForEach(Self.dictationLocales, id: \.identifier) { locale in
              Text(Self.displayName(for: locale)).tag(locale.identifier)
            }
          }
          .pickerStyle(.menu)
        }

        Section {
          NavigationLink("GigaChat") {
            GigaChatSettingsView()
          }
          NavigationLink("YandexGPT") {
            YandexGPTSettingsView()
          }
          NavigationLink("Local Model (FastVLM)") {
            LocalMLXSettingsView()
          }
        } footer: {
          Text("Keys and model download for the three backends that run straight from this phone. Pick which one answers under Intelligence above.")
        }

        Section {
          Button("Reset to Defaults") {
            showResetConfirmation = true
          }
          .foregroundColor(.red)
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Done") { dismiss() }
            .fontWeight(.semibold)
        }
      }
      .alert("Reset Settings", isPresented: $showResetConfirmation) {
        Button("Reset", role: .destructive) {
          settings.resetAll()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This will reset all settings to the values built into the app.")
      }
    }
  }
}
