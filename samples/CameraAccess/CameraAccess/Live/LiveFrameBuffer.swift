// VisionClaw - LiveFrameBuffer.swift
// Последний кадр из очков — и решение о том, стоит ли его вообще отправлять.
//
// Очки отдают ~24 кадра в секунду. Отправлять их в модель нельзя ни по деньгам (зрение у GigaChat
// и Яндекса платное за каждый кадр), ни по смыслу: на ходу почти все кадры смазаны, и модель
// честно отвечает про смазанное пятно.
//
// Поэтому здесь три вещи, и все три нужны:
//
//   1. Дросселирование до 1 кадра в секунду. Ровно то же делает AI-Smart-Glasses, откуда взят
//      ориентир; больше не нужно ни одному из режимов.
//   2. Отпечаток сцены 32x32 в сером. Дешёвый способ спросить «картинка вообще менялась?».
//      Стоять перед одним экспонатом и платить за один и тот же кадр каждые пятнадцать секунд —
//      это не режим гида, это счётчик.
//   3. Проверка на покой. Кадр берётся, только если последнюю секунду сцена почти не менялась.
//      Это и отсев смаза, и признак того, что человек на что-то СМОТРИТ, а не проходит мимо.

import CoreImage
import CoreVideo
import UIKit

@MainActor
final class LiveFrameBuffer: ObservableObject {
    /// Свежий кадр, пригодный для отправки. Nil, пока не пришёл первый.
    @Published private(set) var latest: UIImage?
    /// Сколько кадров прошло обработку — для отладки, не для интерфейса.
    @Published private(set) var processedCount = 0

    /// Насколько должны отличаться отпечатки, чтобы считать сцену сменившейся. 0.06 подобрано под
    /// шум матрицы: ниже — срабатывает на дрожании головы, выше — не замечает смену экспоната.
    var changeThreshold: Double = 0.06
    /// Насколько кадр должен совпадать с предыдущим, чтобы считаться спокойным.
    private let stillnessThreshold: Double = 0.025
    /// Сколько подряд спокойных кадров нужно. При 1 Гц это примерно секунда.
    private let stillnessFrames = 2

    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var lastProcessed = Date.distantPast
    private let interval: TimeInterval = 1.0

    private var signature: [UInt8] = []
    private var previousSignature: [UInt8] = []
    private var calmStreak = 0
    /// Отпечаток кадра, который уже уходил в модель.
    private var sentSignature: [UInt8] = []

    /// Сцена не дёргается — можно снимать.
    var isSteady: Bool { calmStreak >= stillnessFrames }

    /// Сцена отличается от той, что уже отправляли.
    var hasChangedSinceSent: Bool {
        guard !sentSignature.isEmpty else { return true }
        return Self.difference(signature, sentSignature) > changeThreshold
    }

    func reset() {
        latest = nil
        signature = []
        previousSignature = []
        sentSignature = []
        calmStreak = 0
        processedCount = 0
        lastProcessed = .distantPast
    }

    /// Отметить, что этот кадр ушёл в модель.
    func markSent() {
        sentSignature = signature
    }

    /// Вызывается на каждый декодированный кадр. Почти всегда выходит сразу.
    nonisolated func ingest(_ pixelBuffer: CVPixelBuffer) {
        Task { @MainActor in self.process(pixelBuffer) }
    }

    private func process(_ pixelBuffer: CVPixelBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastProcessed) >= interval else { return }
        lastProcessed = now

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        // 1024 по длинной стороне: зрительным моделям больше не нужно, а трафик и время кодирования
        // растут квадратично.
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return }
        let scale = min(1.0, 1024 / max(extent.width, extent.height))
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return }

        let image = UIImage(cgImage: cgImage)
        latest = image
        processedCount += 1

        previousSignature = signature
        signature = Self.makeSignature(cgImage)
        if previousSignature.isEmpty {
            calmStreak = 0
        } else if Self.difference(signature, previousSignature) <= stillnessThreshold {
            calmStreak += 1
        } else {
            calmStreak = 0
        }
    }

    // MARK: Отпечаток

    /// 32x32 в оттенках серого. Не перцептивный хеш и не должен им быть: нужен ответ на вопрос
    /// «это та же картинка или другая», а не устойчивость к поворотам и обрезке.
    nonisolated static func makeSignature(_ cgImage: CGImage) -> [UInt8] {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let space = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(data: &pixels, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side,
                                      space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return [] }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels
    }

    /// Средняя разница яркости, 0…1.
    nonisolated static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var total = 0
        for i in 0..<a.count {
            total += abs(Int(a[i]) - Int(b[i]))
        }
        return Double(total) / Double(a.count) / 255.0
    }
}
