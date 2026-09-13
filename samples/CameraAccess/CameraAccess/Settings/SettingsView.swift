// VisionClaw - SettingsView.swift
// Настройки одним списком с иконками, как в системных.
//
// Раньше это была плоская форма из одинаковых серых строк, где ключ GigaChat лежал рядом с выбором
// языка диктовки и настройкой памяти. Разделено на то, о чём человек думает отдельно: чем отвечать,
// что приложение слышит, что помнит, чем снимает.

import Speech
import SwiftUI

struct SettingsView: View {
    private let settings = SettingsManager.shared

    @State private var showResetConfirmation = false
    @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.automatic.rawValue
    @AppStorage(IntelligenceEngine.defaultsKey) private var intelligenceRaw = IntelligenceEngine.gigachat.rawValue
    @AppStorage(SettingsManager.speechLocaleKey) private var speechLocaleRaw = ""
    @AppStorage(SettingsManager.memoryTurnsKey) private var memoryTurns = 6
    @AppStorage(GlassesAssistant.enabledKey) private var assistantEnabled = false
    @AppStorage(GlassesAssistant.phraseKey) private var assistantPhrase = GlassesAssistant.defaultPhrase
    @StateObject private var assistant = GlassesAssistant.shared
    @StateObject private var hub = AudioCaptureHub.shared

    private var engine: IntelligenceEngine {
        IntelligenceEngine(rawValue: intelligenceRaw) ?? .gigachat
    }

    var body: some View {
        NavigationStack {
            List {
                modelSection
                assistantSection
                voiceSection
                cameraSection
                memorySection
                dataSection
            }
            .navigationTitle("Настройки")
            .onChange(of: assistantEnabled) { _, _ in Task { await assistant.refresh() } }
            .onChange(of: assistantPhrase) { _, _ in Task { await assistant.refresh() } }
            .alert("Сбросить настройки?", isPresented: $showResetConfirmation) {
                Button("Сбросить", role: .destructive) { settings.resetAll() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Все параметры вернутся к значениям по умолчанию. История и скачанные модели останутся.")
            }
        }
    }

    // MARK: Модель

    private var modelSection: some View {
        Section {
            Picker(selection: $intelligenceRaw) {
                ForEach(IntelligenceEngine.allCases, id: \.rawValue) { option in
                    Text(option.label).tag(option.rawValue)
                }
            } label: {
                SettingsRow(icon: "sparkles", tint: .brand, title: "Отвечает")
            }

            NavigationLink {
                GigaChatSettingsView()
            } label: {
                SettingsRow(icon: "key.fill", tint: .green, title: "GigaChat",
                            subtitle: settings.gigaChatAuthKey.isEmpty ? "Ключ не задан" : "Настроен")
            }
            NavigationLink {
                YandexGPTSettingsView()
            } label: {
                SettingsRow(icon: "key.fill", tint: .red, title: "YandexGPT",
                            subtitle: settings.yandexGPTApiKey.isEmpty ? "Ключ не задан" : "Настроен")
            }
            NavigationLink {
                LocalMLXSettingsView()
            } label: {
                SettingsRow(icon: "cpu", tint: .indigo, title: "Локальная модель",
                            subtitle: "FastVLM — работает без сети")
            }
        } header: {
            Text("Модель")
        } footer: {
            Text(engineFooter)
        }
    }

    private var engineFooter: String {
        switch engine {
        case .gigachat: return "GigaChat от Сбера, запрос уходит прямо с телефона."
        case .yandexgpt: return "YandexGPT от Яндекс Облака, запрос уходит прямо с телефона."
        case .localMLX: return "Работает целиком на устройстве: без аккаунта, без сети, бесплатно."
        }
    }

    // MARK: Ассистент

    private var assistantSection: some View {
        Section {
            Toggle(isOn: $assistantEnabled) {
                SettingsRow(icon: "waveform", tint: .orange, title: "Слушать фразу",
                            subtitle: assistantEnabled ? "Работает и в фоне" : "Выключено")
            }
            if assistantEnabled {
                LabeledContent("Фраза") {
                    TextField(GlassesAssistant.defaultPhrase, text: $assistantPhrase)
                        .multilineTextAlignment(.trailing)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
                NavigationLink {
                    HotCommandsView()
                } label: {
                    SettingsRow(icon: "bolt.fill", tint: .yellow, title: "Горячие фразы",
                                subtitle: "Команды без обращения")
                }
                if hub.isSuspended {
                    StatusLine(kind: .idle, text: "Пауза — играет звук в другом приложении")
                } else if let status = assistant.status {
                    StatusLine(kind: .good, text: status)
                }
                if let error = assistant.lastError {
                    StatusLine(kind: .warning, text: error)
                }
            }
        } header: {
            Text("Голосовой ассистент")
        } footer: {
            Text(assistantEnabled
                 ? "Скажите фразу и вопрос — «\(assistantPhrase), что ты видишь». Снимок делается "
                   + "автоматически, ответ читается вслух. Пока играет музыка или идёт звонок, "
                   + "микрофон отдаётся системе: это сохраняет качество звука и не даёт словам песни "
                   + "срабатывать как команды, но и услышать вас в это время приложение не может."
                 : "Спрашивать очки голосом, не доставая телефон.")
        }
    }

    // MARK: Голос

    private var voiceSection: some View {
        Section {
            Picker(selection: $speechLocaleRaw) {
                Text("Как на телефоне (\(systemSpeechLanguageName))").tag("")
                ForEach(Self.dictationLocales, id: \.identifier) { locale in
                    Text(Self.displayName(for: locale)).tag(locale.identifier)
                }
            } label: {
                SettingsRow(icon: "mic.fill", tint: .blue, title: "Язык распознавания")
            }
        } header: {
            Text("Голос")
        } footer: {
            Text("Язык, который слушает микрофон в чате и в голосовых командах.")
        }
    }

    // MARK: Камера

    private var cameraSection: some View {
        Section {
            Picker(selection: $captureSourceRaw) {
                ForEach(CaptureSource.allCases, id: \.rawValue) { source in
                    Label(source.label, systemImage: source.symbol).tag(source.rawValue)
                }
            } label: {
                SettingsRow(icon: "camera.fill", tint: .teal, title: "Источник")
            }
        } header: {
            Text("Камера")
        } footer: {
            Text(cameraFooter)
        }
    }

    private var cameraFooter: String {
        switch CaptureSource(rawValue: captureSourceRaw) ?? .automatic {
        case .automatic:
            return "Очки, когда подключены, иначе телефон. Активный источник всегда виден в шапке чата."
        case .glasses:
            return "Всегда очки. Подключить их можно из шапки чата."
        case .iPhoneCamera:
            return "Всегда камера телефона, даже с подключёнными очками."
        }
    }

    // MARK: Память

    private var memorySection: some View {
        Section {
            Picker(selection: $memoryTurns) {
                Text("Выключена").tag(0)
                Text("4 сообщения").tag(4)
                Text("6 сообщений").tag(6)
                Text("10 сообщений").tag(10)
            } label: {
                SettingsRow(icon: "brain", tint: .purple, title: "Помнить диалог")
            }
        } header: {
            Text("Память")
        } footer: {
            // Стоит сказать прямо: это повторяющаяся, а не разовая цена.
            Text("GigaChat и YandexGPT ничего не хранят между запросами, поэтому выбранное окно "
                 + "уходит на сервер заново с каждым вопросом и оплачивается каждый раз. Локальная "
                 + "модель бесплатна в любом случае. При смене модели чат начинается заново.")
        }
    }

    // MARK: Данные

    private var dataSection: some View {
        Section {
            NavigationLink {
                HistorySettingsView()
            } label: {
                SettingsRow(icon: "externaldrive.fill", tint: .gray, title: "Хранение истории",
                            subtitle: "Срок и размер")
            }
            Button(role: .destructive) {
                showResetConfirmation = true
            } label: {
                SettingsRow(icon: "arrow.counterclockwise", tint: .pink, title: "Сбросить настройки")
            }
        } header: {
            Text("Данные")
        }
    }

    // MARK: Языки диктовки

    /// Языки, на которых этот телефон действительно умеет распознавать речь. Берутся из системы, а
    /// не из списка в коде, поэтому языковой пакет, установленный позже, просто появится здесь.
    private static let dictationLocales: [Locale] = {
        SFSpeechRecognizer.supportedLocales().sorted { displayName(for: $0) < displayName(for: $1) }
    }()

    private static func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private var systemSpeechLanguageName: String {
        let identifier = Locale.preferredLanguages.first ?? Locale.current.identifier
        return Self.displayName(for: Locale(identifier: identifier))
    }
}
