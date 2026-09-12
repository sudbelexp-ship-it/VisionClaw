// VisionClaw - GigaChatTrustDelegate.swift
// URLSessionDelegate that trusts the Минцифры (Russian Ministry of Digital Development) root CA
// for GigaChat hosts.
//
// GigaChat API (*.devices.sberbank.ru) presents a certificate chain from a Russian certificate
// authority that iOS doesn't trust out of the box — without this delegate, the TLS handshake to
// GigaChat fails even with ATS fully relaxed (ATS controls policy like minimum TLS version, not
// the certificate chain trust evaluation itself, which is a separate, lower-level check). Applied
// ONLY to the relevant hosts; every other host gets the standard system check.
//
// Ported directly from OpenVision (D:\OpenVision\OpenVision\Services\Sber\SberTrustDelegate.swift)
// — including the diagnostic capture added there after GigaChat's TLS kept failing even with
// correct certificates bundled AND the system-wide Минцифры trust profile installed on the test
// device: `lastTrustEvaluationError` is nil whenever the failure happens before our delegate even
// sees a certificate challenge, which is itself diagnostic information (points at a TLS-handshake-
// level problem, not a trust-chain one). This is unresolved as of the port — see NOTES if present.

import Foundation
import Security

final class GigaChatTrustDelegate: NSObject, URLSessionDelegate {

    private let anchorCertificates: [SecCertificate]

    /// The exact reason the last certificate check failed — the only way to see WHY without a
    /// Mac/Xcode: URLSession's own `error.localizedDescription` is always the same generic text
    /// ("A TLS error caused..."), while the real reason (which step of the chain didn't match —
    /// expired, missing intermediate, host mismatch, etc.) only shows up inside
    /// `SecTrustEvaluateWithError`. GigaChatSettingsView appends this to the error shown in the UI.
    /// Static: the delegate lives for the app's lifetime (created once in GigaChatClient/GigaChatAuth
    /// init, not per request), so this is just "the last time our delegate saw a cert challenge at
    /// all," not per-instance state.
    static private(set) var lastTrustEvaluationError: String?

    override init() {
        self.anchorCertificates = Self.loadAnchorCertificates()
        super.init()
        if anchorCertificates.isEmpty {
            NSLog("[GigaChat] WARNING: Минцифры certificates not loaded from bundle — GigaChat requests will fail with a TLS error")
        }
    }

    /// How many Минцифры certificates actually made it into the bundle (expect 2: root +
    /// intermediate) — for a diagnostics screen, the only way to check this without a Mac/Xcode.
    static func bundledCertificateCount() -> Int {
        loadAnchorCertificates().count
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host
        guard host.hasSuffix(GigaChatConstants.trustedHostSuffix), !anchorCertificates.isEmpty else {
            // Not a GigaChat host (or certificates never loaded) — standard system check.
            completionHandler(.performDefaultHandling, nil)
            return
        }

        SecTrustSetAnchorCertificates(serverTrust, anchorCertificates as CFArray)
        SecTrustSetAnchorCertificatesOnly(serverTrust, false)

        var evalError: CFError?
        if SecTrustEvaluateWithError(serverTrust, &evalError) {
            Self.lastTrustEvaluationError = nil
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            // What the server actually presented, not just WHY it didn't match — e.g. if the
            // server hands back a leaf signed by a completely different intermediate than our
            // "Russian Trusted Sub CA", the error string alone won't say so, but the presented
            // chain's subject list shows it directly.
            let presentedChain = (SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate]) ?? []
            let subjects = presentedChain.map { cert -> String in
                (SecCertificateCopySubjectSummary(cert) as String?) ?? "?"
            }.joined(separator: " -> ")
            let detail = evalError.map { String(describing: $0) } ?? "unknown"
            Self.lastTrustEvaluationError = "\(detail) | server chain: \(subjects.isEmpty ? "empty" : subjects)"
            NSLog("[GigaChat] certificate check failed for %@: %@", host, Self.lastTrustEvaluationError ?? "")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    // MARK: - Loading certificates from the bundle

    /// Root + intermediate (Sub CA) — in case the GigaChat server doesn't send the intermediate
    /// itself in the chain (common for Минцифры-issued sites).
    private static func loadAnchorCertificates() -> [SecCertificate] {
        ["russian_trusted_root_ca", "russian_trusted_sub_ca"].compactMap { name in
            guard let url = findResourceURL(named: name, extension: "pem"),
                  let pemData = try? Data(contentsOf: url),
                  let der = derData(fromPEM: pemData) else {
                NSLog("[GigaChat] not found in bundle: %@.pem", name)
                return nil
            }
            return SecCertificateCreateWithData(nil, der as CFData)
        }
    }

    /// `Bundle.main.url(forResource:withExtension:)` without `subdirectory:` only looks at the
    /// bundle root — try root, then a "certs" subdirectory, then a full bundle walk as a last
    /// resort in case the actual on-disk placement differs from either guess (see OpenVision's
    /// history: this exact lookup mattered once the resources were confirmed to actually be
    /// copied into the bundle at all — see project.pbxproj's PBXResourcesBuildPhase for that half).
    private static func findResourceURL(named name: String, extension ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "certs") {
            return url
        }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: Bundle.main.bundleURL, includingPropertiesForKeys: nil
        ) else { return nil }
        for case let url as URL in enumerator
        where url.pathExtension == ext && url.deletingPathExtension().lastPathComponent == name {
            return url
        }
        return nil
    }

    /// PEM = base64(DER) wrapped in `-----BEGIN/END CERTIFICATE-----` lines.
    private static func derData(fromPEM pem: Data) -> Data? {
        guard let text = String(data: pem, encoding: .utf8) else { return nil }
        let base64 = text
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        return Data(base64Encoded: base64)
    }
}
