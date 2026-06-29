import Foundation
import Speech

/// Request user authorization for speech recognition.
/// Returns a heap-allocated C string: "authorized" | "denied" | "restricted" | "notDetermined".
/// Caller must free with free_speech_result().
@_cdecl("request_speech_permission_ffi")
public func requestSpeechPermissionFfi() -> UnsafeMutablePointer<CChar>? {
    var status = "notDetermined"
    let sema = DispatchSemaphore(value: 0)

    SFSpeechRecognizer.requestAuthorization { authStatus in
        switch authStatus {
        case .authorized:    status = "authorized"
        case .denied:        status = "denied"
        case .restricted:    status = "restricted"
        case .notDetermined: status = "notDetermined"
        @unknown default:    status = "unknown"
        }
        sema.signal()
    }

    sema.wait()
    return strdup(status)
}

/// Recognize speech from an audio file.
/// filePath: absolute path to audio file (WAV, M4A, FLAC, MP3, etc.)
/// lang:     BCP-47 locale identifier, e.g. "en-US", "zh-CN"
/// Returns a heap-allocated C string with the transcription.
/// On error, returns a string starting with "__error__:".
/// Caller must free with free_speech_result().
@_cdecl("recognize_speech_ffi")
public func recognizeSpeechFfi(
    filePathPtr: UnsafePointer<CChar>,
    langPtr: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>? {
    let filePath = String(cString: filePathPtr)
    let lang = String(cString: langPtr)

    var result = "__error__:unknown"
    let sema = DispatchSemaphore(value: 0)
    var signaled = false

    func signal(_ value: String) {
        guard !signaled else { return }
        signaled = true
        result = value
        sema.signal()
    }

    let authStatus = SFSpeechRecognizer.authorizationStatus()
    guard authStatus == .authorized else {
        return strdup("__error__:Speech recognition not authorized (status: \(authStatus.rawValue)). Call requestSpeechPermission() first.")
    }

    let locale = Locale(identifier: lang)
    guard let recognizer = SFSpeechRecognizer(locale: locale) else {
        return strdup("__error__:SFSpeechRecognizer could not be created for locale: \(lang)")
    }
    guard recognizer.isAvailable else {
        return strdup("__error__:Speech recognizer is not available for locale: \(lang)")
    }

    let url = URL(fileURLWithPath: filePath)
    let request = SFSpeechURLRecognitionRequest(url: url)
    request.shouldReportPartialResults = false
    request.addsPunctuation = true

    recognizer.recognitionTask(with: request) { speechResult, error in
        if let error = error {
            signal("__error__:\(error.localizedDescription)")
        } else if let speechResult = speechResult, speechResult.isFinal {
            signal(speechResult.bestTranscription.formattedString)
        }
    }

    sema.wait()
    return strdup(result)
}

@_cdecl("free_speech_result")
public func freeSpeechResult(_ ptr: UnsafeMutablePointer<CChar>?) {
    free(ptr)
}
