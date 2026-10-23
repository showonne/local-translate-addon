import Foundation
import Translation

private enum TranslateErrorCode: String {
    case unsupportedOSVersion = "ERR_TRANSLATE_UNSUPPORTED_OS_VERSION"
    case languagePairNotInstalled = "ERR_TRANSLATE_LANGUAGE_PAIR_NOT_INSTALLED"
    case languagePairNotReady = "ERR_TRANSLATE_LANGUAGE_PAIR_NOT_READY"
    case failed = "ERR_TRANSLATE_FAILED"
}

@_cdecl("is_translate_text_support_ffi")
public func isTranslateTextSupportFfi() -> Bool {
    if #available(macOS 26, *) {
        return true
    }
    return false
}

/// Exported C symbol — called from Rust via FFI (on a libuv thread pool thread).
/// Dispatches async Translation.framework work to the main dispatch queue so the
/// main thread's RunLoop (pumped by Electron's Cocoa event loop in the main process)
/// can deliver XPC response continuations. Blocks the calling thread via semaphore.
/// Returns a heap-allocated C string. Caller must free with free_translate_result().
/// On error, returns "__error__:<code>:<message>".
@_cdecl("translate_text_ffi")
public func translateTextFfi(
    textPtr: UnsafePointer<CChar>,
    targetLangPtr: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>? {
    let text = String(cString: textPtr)
    let targetLang = String(cString: targetLangPtr)

    var result: String = "__error__:\(TranslateErrorCode.failed.rawValue):unknown"
    let sema = DispatchSemaphore(value: 0)

    DispatchQueue.main.async {
        Task {
            do {
                result = try await performTranslation(text: text, targetLang: targetLang)
            } catch {
                let code = translateErrorCode(for: error)
                result = "__error__:\(code.rawValue):\(error.localizedDescription)"
            }
            sema.signal()
        }
    }

    sema.wait()
    return strdup(result)
}

private func translateErrorCode(for error: Error) -> TranslateErrorCode {
    let nsError = error as NSError
    guard nsError.domain == "MacosTranslate" else {
        return .failed
    }

    switch nsError.code {
    case -1:
        return .unsupportedOSVersion
    case -2:
        return .languagePairNotInstalled
    case -3:
        return .languagePairNotReady
    default:
        return .failed
    }
}

@_cdecl("free_translate_result")
public func freeTranslateResult(_ ptr: UnsafeMutablePointer<CChar>?) {
    free(ptr)
}

private func performTranslation(text: String, targetLang: String) async throws -> String {
    if #available(macOS 26, *) {
        return try await performTranslationModern(text: text, targetLang: targetLang)
    } else {
        throw NSError(
            domain: "MacosTranslate",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Translation.framework session API requires macOS 26+"]
        )
    }
}

private let installedPairPollInterval: Duration = .milliseconds(200)
private let installedPairPollBudget: Duration = .seconds(2)

private func languagePairNotInstalledError(target: String) -> NSError {
    NSError(domain: "MacosTranslate", code: -2,
        userInfo: [NSLocalizedDescriptionKey: "No installed language pair for target: \(target)"])
}

private func unsupportedTargetError(target: String) -> NSError {
    NSError(domain: "MacosTranslate", code: -4,
        userInfo: [NSLocalizedDescriptionKey: "No supported language pair for target: \(target)"])
}

private func languagePairNotReadyError(target: String) -> NSError {
    NSError(domain: "MacosTranslate", code: -3,
        userInfo: [NSLocalizedDescriptionKey: "Language availability for target \(target) was not ready within \(installedPairPollBudget)"])
}

@available(macOS 26, *)
private func installedSource(
    _ availability: LanguageAvailability,
    among supported: [Locale.Language],
    to target: Locale.Language
) async -> Locale.Language? {
    for lang in supported {
        if await availability.status(from: lang, to: target) == .installed {
            return lang
        }
    }
    return nil
}

// translationd reports installed pairs as .supported for a few hundred ms after a cold launch.
@available(macOS 26, *)
private func waitForInstalledSource(
    _ availability: LanguageAvailability,
    among supported: [Locale.Language],
    to target: Locale.Language
) async -> Locale.Language? {
    let clock = ContinuousClock()
    let deadline = clock.now + installedPairPollBudget
    while true {
        if let source = await installedSource(availability, among: supported, to: target) {
            return source
        }
        if clock.now >= deadline {
            return nil
        }
        try? await Task.sleep(for: installedPairPollInterval)
    }
}

@available(macOS 26, *)
private func isNotInstalled(_ error: Error) -> Bool {
    guard let error = error as? TranslationError else { return false }
    if case .notInstalled = error { return true }
    return false
}

@available(macOS 26, *)
private func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
    let session = TranslationSession(installedSource: source, target: target)
    return try await session.translate(text).targetText
}

// Status never reached .installed within the budget: either nothing is installed or translationd is
// still publishing availability. Only the engine itself can tell those apart.
@available(macOS 26, *)
private func translateWithoutInstalledStatus(
    _ text: String,
    _ availability: LanguageAvailability,
    among supported: [Locale.Language],
    to target: Locale.Language,
    targetLang: String
) async throws -> String {
    var candidates = 0
    var notInstalled = 0
    for lang in supported {
        if await availability.status(from: lang, to: target) == .unsupported {
            continue
        }
        candidates += 1
        do {
            return try await translate(text, from: lang, to: target)
        } catch {
            if isNotInstalled(error) {
                notInstalled += 1
            }
        }
    }
    if candidates == 0 {
        throw unsupportedTargetError(target: targetLang)
    }
    if notInstalled == candidates {
        throw languagePairNotInstalledError(target: targetLang)
    }
    throw languagePairNotReadyError(target: targetLang)
}

@available(macOS 26, *)
private func performTranslationModern(text: String, targetLang: String) async throws -> String {
    let targetLocale = Locale.Language(identifier: targetLang)
    let availability = LanguageAvailability()
    let supported = await availability.supportedLanguages

    if let source = await waitForInstalledSource(availability, among: supported, to: targetLocale) {
        do {
            return try await translate(text, from: source, to: targetLocale)
        } catch where isNotInstalled(error) {
            throw languagePairNotInstalledError(target: targetLang)
        }
    }

    return try await translateWithoutInstalledStatus(
        text, availability, among: supported, to: targetLocale, targetLang: targetLang)
}
