// VisionClaw - TranslatorControl.swift
// The one wire between "включи переводчик" said out loud and the translator screen.
//
// A hot command runs in a service that has no idea a UI exists, and the translator is a SwiftUI
// screen presented from the chat. Rather than hand the assistant a reference to a view (which
// would leak the view's lifetime into a background listener), it flips two flags here, and the
// views watch them. Whoever is on screen reacts; if nobody is, the request waits, so saying the
// phrase with the phone in a pocket still opens the translator the moment the app is looked at.

import Foundation

@MainActor
final class TranslatorControl: ObservableObject {
    static let shared = TranslatorControl()
    private init() {}

    /// True while the translator screen should be open.
    @Published var isPresented = false
    /// Bumped to ask the open screen to start or stop interpreting. A counter rather than a Bool
    /// because the same request can legitimately be made twice in a row, and a Bool that is already
    /// true produces no change for a view to react to.
    @Published private(set) var startTicket = 0
    @Published private(set) var stopTicket = 0

    func requestStart() {
        isPresented = true
        startTicket += 1
    }

    func requestStop() {
        stopTicket += 1
        // The screen stays open: someone who stopped interpreting usually wants to read back what
        // was said, and closing it out from under them would throw that away.
    }
}
