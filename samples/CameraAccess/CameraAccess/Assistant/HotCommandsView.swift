// VisionClaw - HotCommandsView.swift
// Editing the phrases that act without the trigger word.

import SwiftUI

struct HotCommandsView: View {
    @StateObject private var store = HotCommandStore.shared
    @State private var newPhrase = ""
    @State private var newAction: HotCommand.Action = .ask

    var body: some View {
        Form {
            Section {
                ForEach($store.commands) { $command in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Фраза", text: $command.phrase)
                                .autocapitalization(.none)
                                .autocorrectionDisabled()
                            Toggle("", isOn: $command.isEnabled).labelsHidden()
                        }
                        Picker("Действие", selection: $command.action) {
                            ForEach(HotCommand.Action.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .font(.caption)
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { store.commands.remove(atOffsets: $0) }
            } header: {
                Text("Фразы")
            } footer: {
                // Worth being explicit: this is the one part of the app that acts on speech nobody
                // addressed to it, so the user should know how narrow the matching is.
                Text("Работают сами по себе, без обращения. Фраза засчитывается, только если "
                     + "она начинает сказанное — упоминание в середине предложения не сработает. "
                     + "«Погода» и «Спросить» берут следующее за ними как предмет: «какая погода» "
                     + "и дальше «в Белгороде».")
            }

            Section {
                TextField("Новая фраза", text: $newPhrase)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                Picker("Действие", selection: $newAction) {
                    ForEach(HotCommand.Action.allCases) { Text($0.label).tag($0) }
                }
                Button("Добавить") {
                    let trimmed = newPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    store.commands.append(HotCommand(phrase: trimmed, action: newAction))
                    newPhrase = ""
                }
                .disabled(newPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Добавить")
            }

            Section {
                Button("Вернуть стандартные", role: .destructive) { store.resetToDefaults() }
            } footer: {
                // Said once here rather than left for the user to discover by trying it.
                Text("Музыкой так управлять нельзя: iOS не даёт приложению средств управлять "
                     + "чужим плеером. Apple Music можно было бы напрямую, Spotify — только через "
                     + "его собственный SDK и отдельный вход, Яндекс Музыку — никак.")
            }
        }
        .navigationTitle("Горячие фразы")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }
}
