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
// Владелец состояния очков и хозяин вкладок.
//
// Отвечают теперь все движки прямо с телефона, поэтому экрана звонка нет, как нет серверного плеча
// и LiveKit, которые были нужны OpenAI и Gemini. Очки здесь — камера, а не режим: экран чата и
// ассистент просят у StreamSessionViewModel один кадр, когда он нужен. Привязка вызывается из шапки
// чата, а не подменяет собой весь экран, — непривязанные очки больше не стоят между человеком и
// обычным текстовым вопросом.
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

  /// Привязаны и готовы. Именно от этого зависит «Автоматически», и именно это делает индикатор
  /// источника в шапке честным, а не декоративным.
  private var glassesReady: Bool {
    guard let wearablesViewModel else { return false }
    return wearablesViewModel.registrationState == .registered || wearablesViewModel.hasMockDevice
  }

  var body: some View {
    RootTabView(
      streamViewModel: viewModel,
      glassesReady: glassesReady,
      onConnectGlasses: wearablesViewModel == nil ? nil : { showPairing = true }
    )
    .sheet(isPresented: $showPairing) {
      if let wearablesViewModel {
        NavigationStack {
          HomeScreenView(viewModel: wearablesViewModel)
            .toolbar {
              ToolbarItem(placement: .topBarTrailing) {
                Button("Готово") { showPairing = false }
              }
            }
        }
      }
    }
    // Ассистент живёт вне экранов (он слушает и в фоне), но модель потока очков есть только здесь,
    // поэтому камера передаётся ему замыканием, а не через обращение к SDK изнутри сервиса.
    .task {
      GlassesAssistant.shared.capturePhoto = { [weak viewModel] in
        guard let viewModel else { return nil }
        return await GlassesCamera.singleFrame(from: viewModel)
      }
      await GlassesAssistant.shared.refresh()
    }
    .alert("Ошибка", isPresented: $viewModel.showError) {
      Button("ОК") { viewModel.dismissError() }
    } message: {
      Text(viewModel.errorMessage)
    }
  }
}
