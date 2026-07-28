import Foundation
import Translation

private enum TranslateErrorCode: String {
    case unsupportedOSVersion = "ERR_TRANSLATE_UNSUPPORTED_OS_VERSION"
    case languagePairNotInstalled = "ERR_TRANSLATE_LANGUAGE_PAIR_NOT_INSTALLED"
    case failed = "ERR_TRANSLATE_FAILED"
}

@_cdecl("is_local_translate_available_ffi")
public func isLocalTranslateAvailableFfi() -> Bool {
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

@available(macOS 26, *)
private func performTranslationModern(text: String, targetLang: String) async throws -> String {
    let targetLocale = Locale.Language(identifier: targetLang)
    let availability = LanguageAvailability()
    let supported = await availability.supportedLanguages

    var installedSource: Locale.Language?
    for lang in supported {
        let status = await availability.status(from: lang, to: targetLocale)
        if status == .installed {
            installedSource = lang
            break
        }
    }

    guard let source = installedSource else {
        throw NSError(domain: "MacosTranslate", code: -2,
            userInfo: [NSLocalizedDescriptionKey: "No installed language pair found for target: \(targetLang)"])
    }

    let session = TranslationSession(installedSource: source, target: targetLocale)
    let response = try await session.translate(text)
    return response.targetText
}
