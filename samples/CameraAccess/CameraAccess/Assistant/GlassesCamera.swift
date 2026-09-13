// VisionClaw - GlassesCamera.swift
// One still frame from the glasses, on demand.
//
// Both the chat's camera button and the hands-free assistant need exactly this, and they used to
// need it in two places with two copies of the same fragile sequence. The sequence matters: the
// DAT SDK has no "take a photo" that works from cold — the stream has to be running first — so
// this starts it only if it isn't already, waits for frames, takes the shot, and shuts the stream
// down again if it was the one that started it. That last part is why it is worth sharing: leaving
// the camera running drains the glasses and leaves the capture light on, and the rule for when to
// stop is easy to get wrong in a copy.

import UIKit

enum GlassesCamera {
    /// Up to ~4s for the stream to come up, then ~5s for a frame. Both are generous because
    /// glasses that were asleep need a Bluetooth handshake first, and the alternative to waiting
    /// is telling the user it failed when it was merely slow.
    private static let streamTimeoutTicks = 40
    private static let photoTimeoutTicks = 50
    private static let tick: UInt64 = 100_000_000   // 0.1s

    @MainActor
    static func singleFrame(from viewModel: StreamSessionViewModel) async -> UIImage? {
        let wasStreaming = viewModel.isStreaming
        if !wasStreaming {
            await viewModel.handleStartStreaming()
            for _ in 0..<streamTimeoutTicks {
                if viewModel.isStreaming { break }
                try? await Task.sleep(nanoseconds: tick)
            }
        }
        guard viewModel.isStreaming else { return nil }

        // Clear first: a photo left over from a previous capture would be returned instantly as
        // if it were the new one, which is how "it answered about the wrong thing" happens.
        viewModel.showPhotoPreview = false
        viewModel.capturedPhoto = nil
        viewModel.capturePhoto()

        var photo: UIImage?
        for _ in 0..<photoTimeoutTicks {
            if let captured = viewModel.capturedPhoto {
                photo = captured
                break
            }
            try? await Task.sleep(nanoseconds: tick)
        }

        if !wasStreaming {
            await viewModel.stopSession()
        }
        return photo
    }
}
