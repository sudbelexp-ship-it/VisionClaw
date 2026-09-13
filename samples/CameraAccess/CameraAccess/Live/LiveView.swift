// VisionClaw - LiveView.swift
// Вкладка «Эфир»: то, что видят очки, и разговор об этом.

import SwiftUI

struct LiveView: View {
    let streamViewModel: StreamSessionViewModel?
    let glassesReady: Bool

    @StateObject private var live = LiveSession.shared
    @StateObject private var synth = SpeechSynthesizer.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                preview
                controls
                Divider()
                transcript
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Эфир")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        live.clear()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(live.entries.isEmpty)
                    .accessibilityLabel("Очистить")
                }
            }
            // Экран можно покинуть, но эфир идёт дальше: камера и микрофон нужны и с погашенным
            // экраном, иначе режим гида бессмысленен. Останавливает только кнопка.
        }
    }

    // MARK: Превью

    private var preview: some View {
        ZStack {
            Color.black
            if let frame = streamViewModel?.currentVideoFrame, live.isRunning {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                VStack(spacing: Metrics.small) {
                    Image(systemName: glassesReady ? "eyeglasses" : "eyeglasses.slash")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(glassesReady ? "Камера выключена" : "Очки не подключены")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            if live.isRunning {
                VStack {
                    HStack(spacing: Metrics.tight) {
                        // Красная точка — общепонятный знак «идёт запись». Здесь она честная:
                        // камера действительно включена всё это время.
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text(live.status ?? "В эфире")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Label("\(live.framesSent)", systemImage: "photo")
                            .font(.caption)
                            .accessibilityLabel("Кадров отправлено: \(live.framesSent)")
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, Metrics.small)
                    .padding(.vertical, Metrics.tight)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(Metrics.small)
                    Spacer()
                }
            }
        }
        .frame(height: 210)
        .clipped()
    }

    // MARK: Управление

    private var controls: some View {
        VStack(spacing: Metrics.small) {
            Picker("Режим", selection: $live.modeRaw) {
                ForEach(LiveMode.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .onChange(of: live.modeRaw) { _, _ in live.modeChanged() }

            Text(live.mode.blurb)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let error = live.errorText {
                StatusLine(kind: .warning, text: error)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if live.isRunning {
                StatusLine(kind: synth.isSpeaking ? .busy : .good,
                           text: synth.isSpeaking ? "Говорю — микрофон не слушает" : "Слушаю вас")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            PrimaryButton(title: live.isRunning ? "Остановить эфир" : "Начать эфир",
                          systemName: live.isRunning ? "stop.fill" : "dot.radiowaves.left.and.right",
                          tint: live.isRunning ? .red : .brand) {
                Task {
                    if live.isRunning {
                        live.stop()
                    } else {
                        await live.start(streamViewModel: streamViewModel)
                    }
                }
            }
            .disabled(!glassesReady && !live.isRunning)
        }
        .padding(.horizontal, Metrics.medium)
        .padding(.vertical, Metrics.small)
    }

    // MARK: Лента

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.small) {
                    if live.entries.isEmpty {
                        hint.padding(.top, Metrics.large)
                    }
                    ForEach(live.entries) { entry in
                        LiveRow(entry: entry).id(entry.id)
                    }
                }
                .padding(Metrics.medium)
            }
            .onChange(of: live.entries.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(live.entries.last?.id, anchor: .bottom)
                }
            }
        }
    }

    private var hint: some View {
        VStack(spacing: Metrics.small) {
            Text(live.mode == .guide ? "Режим гида" : "Обычный режим")
                .font(.headline)
            Text(live.mode == .guide
                 ? "Подойдите к чему-нибудь и задержитесь — он расскажет сам. Спрашивать вслух тоже можно: «а это что?»"
                 : "Спрашивайте вслух про то, что перед вами. Можно показать пальцем — он поймёт, на что вы указываете.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Metrics.large)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct LiveRow: View {
    let entry: LiveEntry

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.small) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: Metrics.tight) {
                if let image = entry.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 180, maxHeight: 120)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                Text(entry.text)
                    .font(entry.kind == .question ? .subheadline : .body)
                    .foregroundStyle(entry.kind == .failure ? Color.orange : .primary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch entry.kind {
        case .question: return "person.wave.2"
        case .answer: return "bubble.left"
        case .narration: return "sparkles"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch entry.kind {
        case .question: return .secondary
        case .answer: return .brand
        case .narration: return .yellow
        case .failure: return .orange
        }
    }
}
