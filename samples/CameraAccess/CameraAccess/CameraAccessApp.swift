/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// CameraAccessApp.swift
//
// VisionClaw is a vision assistant first: the app opens looking at the world
// through the phone camera with voice already listening. Glasses are a capture
// source chosen in Settings, not a decision the user has to make at launch --
// the connect/registration flow appears only when that source is selected.
//

import Foundation
import MWDATCore
import SwiftUI

#if canImport(MWDATMockDevice)
import MWDATMockDevice
#endif

@main
struct CameraAccessApp: App {
  /// nil when the Wearables SDK could not start (no hardware, e.g. the
  /// simulator). Accessing `Wearables.shared` after a failed `configure()`
  /// traps, so nothing glasses-related may be built in that case. The camera
  /// experience does not depend on it.
  private let wearables: WearablesInterface?

  init() {
    // Move the FastVLM model store OUT of Caches before anything touches the HuggingFace hub —
    // iOS may purge Caches under storage pressure, which would silently delete downloaded model
    // weights (the app would then re-download a GB+ at connect time). Must run before any
    // HubClient exists.
    FastVLMService.bootstrapModelStore()

    var available: WearablesInterface?
    do {
      try Wearables.configure()
      available = Wearables.shared
    } catch {
      NSLog("[CameraAccess] Wearables SDK unavailable: \(error)")
    }
    self.wearables = available
  }

  var body: some Scene {
    WindowGroup {
      VisionRootView(wearables: wearables)
    }
  }
}

/// Camera-first root. The stream view is always the front door; what varies
/// with the Wearables SDK is only whether the glasses affordances exist.
struct VisionRootView: View {
  let wearables: WearablesInterface?
  /// `-openSettings` presents Settings at launch, so screens can be captured
  /// on a simulator with no GUI to tap through.
  @State private var showSettings = ProcessInfo.processInfo.arguments.contains("-openSettings")
  var body: some View {
    Group {
      if let wearables {
        GlassesCapableRootView(wearables: wearables)
      } else {
        StreamSessionView(wearables: nil, wearablesVM: nil)
      }
    }
    // Meta AI redirects back here to complete glasses registration. Handle the
    // callback at the ROOT so it fires no matter which screen is showing --
    // including the access-code gate. When it lived only inside the unlocked
    // glasses screen, a callback that arrived while that screen was not mounted
    // was dropped, so the DAT grant never completed and connecting looped back
    // to Meta AI forever.
    .onOpenURL { url in
      NSLog("[CameraAccess] onOpenURL: \(url.absoluteString)")
      guard wearables != nil,
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
        components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
      else { return }
      Task {
        do {
          _ = try await Wearables.shared.handleUrl(url)
          NSLog("[CameraAccess] handleUrl completed")
        } catch {
          NSLog("[CameraAccess] handleUrl failed: \(error.localizedDescription)")
        }
      }
    }
    .sheet(isPresented: $showSettings) { SettingsView() }
  }
}

/// The full app when the glasses SDK is present: the same camera-first stream
/// view, plus the registration overlay and mock-device debug menu that only
/// make sense with the SDK available.
private struct GlassesCapableRootView: View {
  let wearables: WearablesInterface
  @StateObject private var viewModel: WearablesViewModel

  #if canImport(MWDATMockDevice)
  // Debug menu for simulating device connections during development
  @StateObject private var debugMenuViewModel = DebugMenuViewModel(mockDeviceKit: MockDeviceKit.shared)
  #endif

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self._viewModel = StateObject(wrappedValue: WearablesViewModel(wearables: wearables))
  }

  var body: some View {
    StreamSessionView(wearables: wearables, wearablesVM: viewModel)
      // Study engagement nudges: request notification permission once and
      // schedule the periodic "look around and ask" reminders.
      .task { NudgeScheduler.requestAuthorizationAndSchedule() }
      // Show error alerts for view model failures
      .alert("Error", isPresented: $viewModel.showError) {
        Button("OK") { viewModel.dismissError() }
      } message: {
        Text(viewModel.errorMessage)
      }
      #if canImport(MWDATMockDevice)
      .sheet(isPresented: $debugMenuViewModel.showDebugMenu) {
        MockDeviceKitView(viewModel: debugMenuViewModel.mockDeviceKitViewModel)
      }
      .overlay {
        DebugMenuView(debugMenuViewModel: debugMenuViewModel)
      }
      #endif

    // The Meta AI callback is handled at the app root (see .onOpenURL there) so
    // it works even while the access-code gate is showing.
  }
}
