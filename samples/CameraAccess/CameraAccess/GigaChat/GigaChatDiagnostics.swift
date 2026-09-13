// VisionClaw - GigaChatDiagnostics.swift
// A battery of on-device probes for the GigaChat connection, plus the screen that runs them.
//
// Why this exists: GigaChat failed for weeks with one useless sentence — "A TLS error caused the
// secure connection to fail." Every distinct cause (blocked network, wrong certificate, ATS
// refusing a non-system-anchored chain, an expired token, a rejected key) produces that same
// sentence through URLSession's `localizedDescription`, so each fix attempt was a guess that cost
// a full build-install-retry cycle. These probes separate the causes from each other in one run,
// on the device, without a Mac:
//
//   1. Bundle    — are the Минцифры anchors in this build, and are they the right ones? Compares
//                  SHA-256 against the fingerprints the live servers actually present.
//   2. TCP       — can we open a plain socket to the host at all? Splits "network/port blocked"
//                  from everything TLS.
//   3. NW TLS    — a Network.framework handshake validating against our anchors ourselves.
//                  Network.framework is NOT subject to App Transport Security, so if this succeeds
//                  while the URLSession probe below fails, ATS is provably the cause.
//   4. URLSession— the real request path, reporting the NSError domain, code and the underlying
//                  OSStatus rather than the cosmetic description.
//
// Read the results top-down: the first failing row is the one to act on.

import CryptoKit
import Foundation
import Network
import Security
import SwiftUI

// MARK: - Result model

struct DiagnosticStep: Identifiable {
    enum Outcome { case pending, running, passed, failed, warning }

    let id = UUID()
    let title: String
    var outcome: Outcome = .pending
    var detail: String = ""
}

// MARK: - Probes

@MainActor
final class GigaChatDiagnostics: ObservableObject {
    @Published private(set) var steps: [DiagnosticStep] = []
    @Published private(set) var isRunning = false

    /// SHA-256 of the two certificates `ngw.devices.sberbank.ru` and `gigachat.devices.sberbank.ru`
    /// chain to, read off the live servers. Bundling a certificate that merely *looks* right is a
    /// silent failure mode, so the bundled bytes are checked against these, not just counted.
    private static let expectedRootSHA256 =
        "D26D2D0231B7C39F92CC738512BA54103519E4405D68B5BD703E9788CA8ECF31"
    private static let expectedSubSHA256 =
        "2155785036C900DBB5F1BB2A1569C80C55595BD6BF94867A29BBDDBC7D88A3F2"

    func run(authKey: String) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        steps = [
            DiagnosticStep(title: "Bundled certificates"),
            DiagnosticStep(title: "TCP to ngw…:9443"),
            DiagnosticStep(title: "TLS via Network.framework (no ATS)"),
            DiagnosticStep(title: "URLSession OAuth request"),
            DiagnosticStep(title: "Trust delegate reached?"),
        ]

        await step(0) { Self.checkBundledCertificates() }
        await step(1) { await Self.checkTCP(host: "ngw.devices.sberbank.ru", port: 9443) }
        await step(2) { await Self.checkNetworkFrameworkTLS(host: "ngw.devices.sberbank.ru", port: 9443) }
        await step(3) { await Self.checkURLSessionOAuth(authKey: authKey) }
        await step(4) { Self.checkDelegateReached() }
    }

    private func step(_ index: Int, _ work: () async -> (DiagnosticStep.Outcome, String)) async {
        steps[index].outcome = .running
        let (outcome, detail) = await work()
        steps[index].outcome = outcome
        steps[index].detail = detail
    }

    /// A copy-paste-able dump, so a failing run can travel out of the phone in one paste.
    var report: String {
        steps.map { step in
            let mark: String
            switch step.outcome {
            case .passed: mark = "PASS"
            case .failed: mark = "FAIL"
            case .warning: mark = "WARN"
            case .running: mark = "…"
            case .pending: mark = "-"
            }
            return "[\(mark)] \(step.title)\n      \(step.detail)"
        }.joined(separator: "\n")
    }

    // MARK: 1 — bundle

    private static func checkBundledCertificates() -> (DiagnosticStep.Outcome, String) {
        let anchors = GigaChatTrustDelegate.bundledAnchors()
        guard !anchors.isEmpty else {
            return (.failed, "No .pem anchors in this build — a packaging bug, not a settings one.")
        }
        let digests = anchors.map { cert -> String in
            let der = SecCertificateCopyData(cert) as Data
            return der.sha256Hex
        }
        let haveRoot = digests.contains(expectedRootSHA256)
        let haveSub = digests.contains(expectedSubSHA256)
        let summary = "\(anchors.count) anchor(s); root \(haveRoot ? "OK" : "MISSING"), sub CA \(haveSub ? "OK" : "MISSING")"
        if haveRoot && haveSub { return (.passed, summary) }
        return (.failed, summary + " — bundled certificates don't match what the servers present.")
    }

    // MARK: 2 — raw TCP

    private static func checkTCP(host: String, port: UInt16) async -> (DiagnosticStep.Outcome, String) {
        let params = NWParameters.tcp
        let result = await connect(host: host, port: port, parameters: params)
        switch result {
        case .success:
            return (.passed, "Socket opened — the host and port are reachable on this network.")
        case .failure(let why):
            return (.failed, "\(why) — the network or the carrier is blocking port \(port), TLS never starts.")
        }
    }

    // MARK: 3 — TLS outside ATS

    private static func checkNetworkFrameworkTLS(host: String, port: UInt16) async -> (DiagnosticStep.Outcome, String) {
        let anchors = GigaChatTrustDelegate.bundledAnchors()
        let tls = NWProtocolTLS.Options()
        let verifyQueue = DispatchQueue(label: "gigachat.diagnostics.verify")
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                SecTrustSetAnchorCertificates(trust, anchors as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, false)
                var error: CFError?
                complete(SecTrustEvaluateWithError(trust, &error))
            },
            verifyQueue
        )
        let params = NWParameters(tls: tls)
        switch await connect(host: host, port: port, parameters: params) {
        case .success:
            return (.passed, "Handshake succeeded against the bundled Минцифры anchors. "
                    + "The certificates and the network are both fine.")
        case .failure(let why):
            return (.failed, "\(why) — the chain itself doesn't validate against our anchors.")
        }
    }

    private enum ConnectResult { case success, failure(String) }

    private static func connect(host: String, port: UInt16, parameters: NWParameters) async -> ConnectResult {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return .failure("bad port") }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let queue = DispatchQueue(label: "gigachat.diagnostics.connect")

        return await withCheckedContinuation { continuation in
            // The continuation must be resumed exactly once: a state handler can fire .failed after
            // the timeout already resolved, and resuming twice traps.
            let finished = Locked(false)
            func settle(_ result: ConnectResult) {
                guard finished.swapTrue() == false else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    settle(.success)
                case .failed(let error):
                    settle(.failure(Self.describe(error)))
                case .waiting(let error):
                    // .waiting means "can't proceed but will keep retrying" — for a probe that is
                    // a failure with a usable reason, not something to sit through.
                    settle(.failure(Self.describe(error)))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 15) { settle(.failure("timed out after 15s")) }
        }
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code): return "POSIX \(code.rawValue) (\(code))"
        case .tls(let status): return "TLS OSStatus \(status) (\(tlsMeaning(status)))"
        case .dns(let code): return "DNS error \(code)"
        @unknown default: return String(describing: error)
        }
    }

    /// The handful of Secure Transport codes that actually show up here; anything else is printed
    /// raw so it can be looked up rather than guessed at.
    private static func tlsMeaning(_ status: OSStatus) -> String {
        switch status {
        case -9807: return "invalid certificate chain"
        case -9808: return "invalid certificate"
        case -9813: return "certificate not trusted"
        case -9814: return "certificate expired"
        case -9836: return "TLS protocol version not supported"
        case -9843: return "server sent a fatal alert"
        case -9802: return "fatal alert"
        default: return "see Security/SecureTransport.h"
        }
    }

    // MARK: 4 — the real path

    private static func checkURLSessionOAuth(authKey: String) async -> (DiagnosticStep.Outcome, String) {
        let key = authKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // TLS fails long before any credential is read, so an empty key still exercises the exact
        // failure under investigation — it just can't tell a good key from a bad one afterwards.
        let probeKey = key.isEmpty ? "ZGlhZ25vc3RpY3M6cHJvYmU=" : key
        do {
            _ = try await GigaChatAuth.shared.forceRefresh(authKey: probeKey)
            return (.passed, "OAuth succeeded — TLS and the key are both good.")
        } catch let error as GigaChatError {
            if case .http(let code, let body) = error {
                // An HTTP status means the handshake completed: TLS is solved, this is auth.
                let trimmed = body.prefix(200)
                if key.isEmpty {
                    return (.passed, "TLS works (server replied HTTP \(code) to the probe key). "
                            + "Enter your real Authorization Key to test authentication.")
                }
                return (.warning, "TLS works; the server rejected the key: HTTP \(code) \(trimmed)")
            }
            return (.failed, error.localizedDescription)
        } catch {
            let ns = error as NSError
            var parts = ["\(ns.domain) \(ns.code)", ns.localizedDescription]
            if let os = ns.userInfo["_kCFStreamErrorCodeKey"] as? Int {
                parts.append("OSStatus \(os) (\(tlsMeaning(OSStatus(os))))")
            }
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                parts.append("underlying \(underlying.domain) \(underlying.code)")
            }
            return (.failed, parts.joined(separator: " | "))
        }
    }

    // MARK: 5 — did our own code ever get a say?

    private static func checkDelegateReached() -> (DiagnosticStep.Outcome, String) {
        let count = GigaChatTrustDelegate.challengeCount
        if count > 0 {
            let detail = GigaChatTrustDelegate.lastTrustEvaluationError
            return (.passed, detail.map { "Reached \(count)×; last check failed: \($0)" }
                    ?? "Reached \(count)×, certificate check passed.")
        }
        return (.warning, "Never reached. The connection died before iOS asked us about the "
                + "certificate — the signature of App Transport Security refusing a chain that "
                + "isn't anchored in Apple's own trust store.")
    }
}

/// Minimal one-shot latch for the connect continuation. A full lock would be overkill; all this
/// needs is "did someone already resume this?" answered atomically.
private final class Locked: @unchecked Sendable {
    private var value: Bool
    private let lock = NSLock()
    init(_ value: Bool) { self.value = value }
    /// Sets the flag and returns what it was before.
    func swapTrue() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let old = value
        value = true
        return old
    }
}

private extension Data {
    var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02X", $0) }.joined()
    }
}

// MARK: - Screen

struct GigaChatDiagnosticsView: View {
    @StateObject private var diagnostics = GigaChatDiagnostics()
    @State private var copied = false
    private let settings = SettingsManager.shared

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await diagnostics.run(authKey: settings.gigaChatAuthKey) }
                } label: {
                    HStack {
                        if diagnostics.isRunning { ProgressView().padding(.trailing, 4) }
                        Text(diagnostics.isRunning ? "Running…" : "Run diagnostics")
                    }
                }
                .disabled(diagnostics.isRunning)
            } footer: {
                Text("Runs four independent probes. The first failing row is the one that matters — "
                     + "each rules a different cause in or out.")
            }

            if !diagnostics.steps.isEmpty {
                Section {
                    ForEach(diagnostics.steps) { step in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                icon(for: step.outcome)
                                Text(step.title).font(.subheadline.weight(.medium))
                            }
                            if !step.detail.isEmpty {
                                Text(step.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section {
                    Button {
                        UIPasteboard.general.string = diagnostics.report
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy full report", systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func icon(for outcome: DiagnosticStep.Outcome) -> some View {
        switch outcome {
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
        case .running: ProgressView()
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
