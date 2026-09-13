/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionView.swift
//
// The app's front door: the chat, plus the glasses plumbing it draws on.
//
// Every engine answers directly from the phone now, so there is no call screen
// and no server leg -- the LiveKit path that OpenAI/Gemini needed is gone.
// Glasses are a camera, not a mode: AskAssistantView asks StreamSessionViewModel
// for a single frame when the camera button is tapped. Pairing is reachable from
// the chat's own menu rather than blocking the whole screen, so an unpaired pair
// of glasses no longer stands between the user and a text question.
//

import MWDATCore
import SwiftUI
import UIKit

struct StreamSessionView: View {
  let wearables: WearablesInterface?
  private let wearablesViewModel: WearablesViewModel?
  @StateObject private var viewModel: StreamSessionViewModel
  @State private var showPairing = false

  init(wearables: WearablesInterface?, wearablesVM: WearablesViewModel?) {
    self.wearables = wearables
    self.wearablesViewModel = wearablesVM
    self._viewModel = StateObject(wrappedValue: StreamSessionViewModel(wearables: wearables))
  }

  /// Paired and usable. "Automatic" resolves to the glasses only when this is true, which is what
  /// makes the source indicator in the header honest rather than aspirational.
  private var glassesReady: Bool {
    guard let wearablesViewModel else { return false }
    return wearablesViewModel.registrationState == .registered || wearablesViewModel.hasMockDevice
  }

  var body: some View {
    AskAssistantView(
      streamViewModel: viewModel,
      glassesReady: glassesReady,
      onConnectGlasses: wearablesViewModel == nil ? nil : { showPairing = true }
    )
    .sheet(isPresented: $showPairing) {
      if let wearablesViewModel {
        NavigationView {
          HomeScreenView(viewModel: wearablesViewModel)
            .toolbar {
              ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { showPairing = false }
              }
            }
        }
      }
    }
    .alert("Error", isPresented: $viewModel.showError) {
      Button("OK") { viewModel.dismissError() }
    } message: {
      Text(viewModel.errorMessage)
    }
  }
}
