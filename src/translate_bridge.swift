import Foundation
import Translation

/// Exported C symbol — called from Rust via FFI (on a libuv thread pool thread).
/// Dispatches async Translation.framework work to the main dispatch queue so the
/// main thread's RunLoop (pumped by Electron's Cocoa event loop) can deliver
/// XPC response continuations. Blocks the calling thread via semaphore.
/// Returns a heap-allocated C string. Caller must free with free_translate_result().
/// On error, returns a string starting with "__error__:".
@_cdecl("translate_text_ffi")
public func translateTextFfi(
    textPtr: UnsafePointer<CChar>,
    targetLangPtr: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>? {
    let text = String(cString: textPtr)
    let targetLang = String(cString: targetLangPtr)

    var result: String = "__error__:unknown"
    let sema = DispatchSemaphore(value: 0)

    DispatchQueue.main.async {
        Task {
            do {
                result = try await performTranslation(text: text, targetLang: targetLang)
            } catch {
                result = "__error__:\(error.localizedDescription)"
            }
            sema.signal()
        }
    }

    sema.wait()
    return strdup(result)
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
