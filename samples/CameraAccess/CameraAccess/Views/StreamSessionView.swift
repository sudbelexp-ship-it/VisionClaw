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
// The app's front door. Every engine now answers directly from the phone
// (GigaChat, YandexGPT, or the on-device FastVLM model), so this is simply the
// ask screen -- the LiveKit call screen, the agent worker and the gateway that
// OpenAI/Gemini needed are gone.
//
// The glasses still matter: StreamSessionViewModel drives the DAT SDK, and
// AskAssistantView reaches into it to capture a single frame on demand. Glasses
// that aren't registered yet get the pairing screen instead.
//

import MWDATCore
import SwiftUI
import UIKit

struct StreamSessionView: View {
  let wearables: WearablesInterface?
  private let wearablesViewModel: WearablesViewModel?
  @StateObject private var viewModel: StreamSessionViewModel
  @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.iPhoneCamera.rawValue

  private var captureSource: CaptureSource {
    CaptureSource(rawValue: captureSourceRaw) ?? .iPhoneCamera
  }

  init(wearables: WearablesInterface?, wearablesVM: WearablesViewModel?) {
    self.wearables = wearables
    self.wearablesViewModel = wearablesVM
    self._viewModel = StateObject(wrappedValue: StreamSessionViewModel(wearables: wearables))
  }

  var body: some View {
    ZStack {
      // Glasses as the capture source but not paired yet is the one case that needs a
      // different screen: asking a question is fine, but the camera button would fail
      // every time until the pairing in the Meta AI app is done.
      if captureSource == .glasses,
         let wearablesViewModel,
         wearablesViewModel.registrationState != .registered,
         !wearablesViewModel.hasMockDevice {
        HomeScreenView(viewModel: wearablesViewModel)
      } else {
        AskAssistantView(streamViewModel: viewModel)
      }
    }
    .alert("Error", isPresented: $viewModel.showError) {
      Button("OK") { viewModel.dismissError() }
    } message: {
      Text(viewModel.errorMessage)
    }
  }
}
