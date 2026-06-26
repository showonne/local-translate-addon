import Foundation
import Translation

/// Exported C symbol — called from Rust via FFI.
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

    Task {
        do {
            result = try await performTranslation(text: text, targetLang: targetLang)
        } catch {
            result = "__error__:\(error.localizedDescription)"
        }
        sema.signal()
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
    } else if #available(macOS 15, *) {
        throw NSError(
            domain: "MacosTranslate",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Translation.framework session API requires macOS 26+"]
        )
    } else {
        throw NSError(
            domain: "MacosTranslate",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Translation.framework requires macOS 15+"]
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
