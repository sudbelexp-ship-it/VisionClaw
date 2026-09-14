// VisionClaw - LiveFrameBuffer.swift
// Последний кадр из очков — и решение о том, стоит ли его вообще отправлять.
//
// Очки отдают ~24 кадра в секунду. Отправлять их в модель нельзя ни по деньгам (зрение у GigaChat
// и Яндекса платное за каждый кадр), ни по смыслу: на ходу почти все кадры смазаны, и модель
// честно отвечает про смазанное пятно.
//
// Поэтому здесь четыре вещи:
//
//   1. Дросселирование до 1 кадра в секунду. Ровно то же делает AI-Smart-Glasses, откуда взят
//      ориентир; больше не нужно ни одному из режимов.
//   2. Отпечаток сцены 32x32 в сером. Дешёвый способ спросить «картинка вообще менялась?».
//      Стоять перед одним экспонатом и платить за один и тот же кадр каждые пятнадцать секунд —
//      это не режим гида, это счётчик.
//   3. Проверка на покой. Кадр берётся, только если последнюю секунду сцена почти не менялась.
//      Это и отсев смаза, и признак того, что человек на что-то СМОТРИТ, а не проходит мимо.
//   4. Распознавание указательного жеста через Vision (VNDetectHumanHandPoseRequest, штатный
//      фреймворк с iOS 14 — сторонних CV-библиотек не нужно). Не просьба к самой модели зрения
//      угадать жест по фото — отдельное, дешёвое распознавание прямо на кадре при throttling до
//      1 Гц, результат которого LiveSession использует как отдельный триггер вопроса.

import CoreImage
import CoreVideo
import UIKit
import Vision

@MainActor
final class LiveFrameBuffer: ObservableObject {
    /// Свежий кадр, пригодный для отправки. Nil, пока не пришёл первый.
    @Published private(set) var latest: UIImage?
    /// Сколько кадров прошло обработку — для отладки, не для интерфейса.
    @Published private(set) var processedCount = 0
    /// Указательный палец виден в последнем обработанном кадре. Уровень, а не однократное
    /// событие — LiveSession сам решает, что делать с фронтом/удержанием этого состояния.
    @Published private(set) var isPointing = false

    /// Насколько должны отличаться отпечатки, чтобы считать сцену сменившейся. 0.06 подобрано под
    /// шум матрицы: ниже — срабатывает на дрожании головы, выше — не замечает смену экспоната.
    var changeThreshold: Double = 0.06
    /// Насколько кадр должен совпадать с предыдущим, чтобы считаться спокойным.
    private let stillnessThreshold: Double = 0.025
    /// Сколько подряд спокойных кадров нужно. При 1 Гц это примерно секунда.
    private let stillnessFrames = 2

    /// CIContext потокобезопасен, поэтому один на всех и рендер прямо на очереди декодера.
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    /// Читается и пишется вне главного актора, отсюда замок.
    private let lock = NSLock()
    nonisolated(unsafe) private var lastProcessed = Date.distantPast
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
        lock.lock()
        lastProcessed = .distantPast
        lock.unlock()
    }

    /// Отметить, что этот кадр ушёл в модель.
    func markSent() {
        sentSignature = signature
    }

    /// Вызывается на каждый декодированный кадр, на очереди декодера. Почти всегда выходит сразу.
    ///
    /// Преобразование делается ЗДЕСЬ, синхронно, а не отправляется на главный актор вместе с
    /// буфером. VideoToolbox отдаёт кадры из пула и переиспользует их: буфер, переданный через
    /// границу актора, к моменту обработки уже может содержать другой кадр — или тот же самый,
    /// если пул вернул его повторно. Именно поэтому гид раз за разом описывал одну и ту же
    /// картинку, хотя на превью (оно идёт другим путём) сцена менялась.
    nonisolated func ingest(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastProcessed) >= interval else {
            lock.unlock()
            return
        }
        lastProcessed = now
        lock.unlock()

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return }
        // 1024 по длинной стороне: зрительным моделям больше не нужно, а трафик и время
        // кодирования растут квадратично.
        let scale = min(1.0, 1024 / max(extent.width, extent.height))
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return }

        let image = UIImage(cgImage: cgImage)
        let signature = Self.makeSignature(cgImage)
        let pointing = Self.detectPointing(cgImage)
        Task { @MainActor in self.apply(image: image, signature: signature, pointing: pointing) }
    }

    private func apply(image: UIImage, signature newSignature: [UInt8], pointing: Bool) {
        latest = image
        isPointing = pointing
        processedCount += 1

        previousSignature = signature
        signature = newSignature
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

    // MARK: Указательный жест

    /// Насколько уверенно Vision должен видеть сустав, чтобы ему вообще доверять.
    private static let jointConfidence: Float = 0.3
    /// Во сколько раз указательный палец должен быть "длиннее" (от запястья до кончика), чем в
    /// среднем остальные три пальца, чтобы считать его вытянутым, а не просто раскрытой ладонью.
    /// Подобрано на глаз по геометрии ладони, не проверено на реальных руках — если срабатывает
    /// на раскрытую ладонь или пропускает явное указание, это первое, что стоит подстроить.
    private static let pointingRatio: CGFloat = 1.3

    /// Указывает ли рука на кадре пальцем — вытянутый указательный при согнутых остальных.
    /// Не перцептивный хеш и не сравнение с предыдущим кадром: разовое суждение по одному снимку,
    /// геометрия ладони на нём или есть, или нет.
    nonisolated static func detectPointing(_ cgImage: CGImage) -> Bool {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first else { return false }
            let points = try observation.recognizedPoints(.all)

            func joint(_ name: VNHumanHandPoseObservation.JointName) -> CGPoint? {
                guard let point = points[name], point.confidence >= jointConfidence else { return nil }
                return point.location
            }
            func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

            guard let wrist = joint(.wrist), let indexTip = joint(.indexTip),
                  let indexMCP = joint(.indexMCP)
            else { return false }

            let curledTips = [joint(.middleTip), joint(.ringTip), joint(.littleTip)].compactMap { $0 }
            // Need at least two of the three other fingertips tracked to trust an average.
            guard curledTips.count >= 2 else { return false }

            let indexReach = distance(indexTip, wrist)
            let averageOtherReach = curledTips.map { distance($0, wrist) }.reduce(0, +)
                / CGFloat(curledTips.count)
            // Extended past the other fingertips by a clear margin, and not folded back onto its
            // own knuckle (which distance(indexTip, wrist) alone wouldn't catch on a closed fist
            // held at an angle).
            return indexReach > averageOtherReach * pointingRatio
                && distance(indexTip, indexMCP) > indexReach * 0.35
        } catch {
            return false
        }
    }
}
