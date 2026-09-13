// VisionClaw - RootTabView.swift
// The app's four places, all one tap away.
//
// Everything except the chat used to live behind an "…" button in a corner: the translator, the
// history, the settings. That is a menu for things you rarely want, and all three of these are
// things you want constantly — so nothing was findable and the app felt like one screen with a
// junk drawer attached.
//
// The translator is a tab rather than a modal for a second reason: a voice command can start it,
// and a modal that appears by itself over whatever you were doing is worse than a tab that simply
// becomes selected.

import SwiftUI

struct RootTabView: View {
    let streamViewModel: StreamSessionViewModel?
    let glassesReady: Bool
    let onConnectGlasses: (() -> Void)?

    @StateObject private var translatorControl = TranslatorControl.shared
    @State private var selection: Tab = .chat

    enum Tab: Hashable { case chat, live, translator, history, settings }

    var body: some View {
        TabView(selection: $selection) {
            AskAssistantView(streamViewModel: streamViewModel,
                             glassesReady: glassesReady,
                             onConnectGlasses: onConnectGlasses)
                .tabItem { Label("Чат", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(Tab.chat)

            LiveView(streamViewModel: streamViewModel, glassesReady: glassesReady)
                .tabItem { Label("Эфир", systemImage: "dot.radiowaves.left.and.right") }
                .tag(Tab.live)

            LiveTranslatorView()
                .tabItem { Label("Переводчик", systemImage: "character.bubble.fill") }
                .tag(Tab.translator)

            HistoryView()
                .tabItem { Label("История", systemImage: "clock.fill") }
                .tag(Tab.history)

            SettingsView()
                .tabItem { Label("Настройки", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .tint(.brand)
        // "Включи переводчик", said out loud, selects the tab instead of throwing a sheet over
        // whatever the user was looking at.
        .onChange(of: translatorControl.isPresented) { _, wantsTranslator in
            if wantsTranslator { selection = .translator }
        }
        .onChange(of: selection) { _, tab in
            // Keep the flag honest when the user navigates by hand, so a later voice command still
            // registers as a change.
            translatorControl.isPresented = (tab == .translator)
        }
    }
}
