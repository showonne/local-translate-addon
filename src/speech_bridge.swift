import AudioToolbox
import AVFAudio
import CoreMedia
import Foundation
import Speech

// One transcription API over whichever system recognizer this macOS can use. Callers never learn which one runs.
//
// FFI results are heap-allocated C strings, freed with free_speech_result(). Failures come back as
// "__error__:<code>:<message>". Rust calls every blocking function here from a thread of its own, never from
// Node's main thread or libuv's thread pool.

enum TranscribeErrorCode: String {
    case unsupportedOSVersion = "ERR_TRANSCRIBE_UNSUPPORTED_OS_VERSION"
    case unsupportedLanguage = "ERR_TRANSCRIBE_UNSUPPORTED_LANGUAGE"
    case modelNotInstalled = "ERR_TRANSCRIBE_MODEL_NOT_INSTALLED"
    case modelDownloadFailed = "ERR_TRANSCRIBE_MODEL_DOWNLOAD_FAILED"
    case audioDecodeFailed = "ERR_TRANSCRIBE_AUDIO_DECODE_FAILED"
    case audioTooLong = "ERR_TRANSCRIBE_AUDIO_TOO_LONG"
    case timeout = "ERR_TRANSCRIBE_TIMEOUT"
    case failed = "ERR_TRANSCRIBE_FAILED"
}

struct TranscribeFailure: Error {
    let code: TranscribeErrorCode
    let message: String
}

enum TranscriptionModelStatus: String {
    case ready
    case downloadRequired
    case unsupported
}

protocol TranscriptionEngine: Sendable {
    /// Never downloads anything or asks for permission.
    func modelStatus(lang: String) async throws -> TranscriptionModelStatus
    func downloadModel(lang: String) async throws
    /// `timeout` nil means the default for the audio's length.
    func transcribe(audio: Data, lang: String, timeout: Duration?) async throws -> String
}

/// The engine behind the public API, or nil when this macOS has none the host can use.
///
/// macOS 26+ always uses SpeechAnalyzer, and never falls back to SFSpeechRecognizer, even when SpeechAnalyzer fails:
/// SFSpeechRecognizer needs NSSpeechRecognitionUsageDescription in the host app's Info.plist and the user's
/// permission, and without the usage description the system kills the process (exit code 134). Loaded in
/// Electron's main process, that is the whole app. SpeechAnalyzer needs neither.
private func currentEngine() -> TranscriptionEngine? {
    if #available(macOS 26, *) {
        return AnalyzerEngine()
    }
    return nil
}

private let statusTimeout: Duration = .seconds(10)

private func defaultTranscribeTimeout(audioSeconds: Double) -> Duration {
    .seconds(30) + .seconds(audioSeconds)
}

// MARK: - FFI

@_cdecl("is_transcribe_audio_support_ffi")
public func isTranscribeAudioSupportFfi() -> Bool {
    if #available(macOS 26, *) {
        return SpeechTranscriber.isAvailable
    }
    return false
}

/// Returns "ready" | "downloadRequired" | "unsupported".
@_cdecl("transcribe_audio_model_status_ffi")
public func transcribeAudioModelStatusFfi(_ langPtr: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let lang = String(cString: langPtr)
    return blockingResult {
        guard let engine = currentEngine() else {
            return TranscriptionModelStatus.unsupported.rawValue
        }
        return try await withTimeout(statusTimeout) {
            try await engine.modelStatus(lang: lang).rawValue
        }
    }
}

/// Returns "" once the model is installed.
@_cdecl("download_transcribe_audio_model_ffi")
public func downloadTranscribeAudioModelFfi(_ langPtr: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let lang = String(cString: langPtr)
    return blockingResult {
        try await requireEngine().downloadModel(lang: lang)
        return ""
    }
}

/// Transcribes in-memory mp3 / m4a / adts / wav audio. `timeoutMs` 0 means the default for the audio's length.
@_cdecl("transcribe_audio_ffi")
public func transcribeAudioFfi(
    bytes: UnsafePointer<UInt8>,
    length: Int,
    langPtr: UnsafePointer<CChar>,
    timeoutMs: UInt32
) -> UnsafeMutablePointer<CChar>? {
    let audio = Data(bytes: bytes, count: length)
    let lang = String(cString: langPtr)
    let timeout: Duration? = timeoutMs > 0 ? .milliseconds(Int64(timeoutMs)) : nil
    return blockingResult {
        try await requireEngine().transcribe(audio: audio, lang: lang, timeout: timeout)
    }
}

@_cdecl("free_speech_result")
public func freeSpeechResult(_ ptr: UnsafeMutablePointer<CChar>?) {
    free(ptr)
}

private func requireEngine() throws -> TranscriptionEngine {
    guard let engine = currentEngine() else {
        throw TranscribeFailure(code: .unsupportedOSVersion, message: "Speech transcription requires macOS 26+")
    }
    return engine
}

private final class ResultBox: @unchecked Sendable {
    var value = ""
}

private func blockingResult(_ work: @escaping @Sendable () async throws -> String) -> UnsafeMutablePointer<CChar>? {
    let box = ResultBox()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            box.value = try await work()
        } catch let failure as TranscribeFailure {
            box.value = "__error__:\(failure.code.rawValue):\(failure.message)"
        } catch {
            box.value = "__error__:\(TranscribeErrorCode.failed.rawValue):\(error.localizedDescription)"
        }
        done.signal()
    }
    done.wait()
    return strdup(box.value)
}

// MARK: - Timeout

private final class FirstResult<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    /// Resumes the continuation for the first caller only, and tells that caller it won.
    @discardableResult
    func finish(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
        return pending != nil
    }
}

/// Fails with ERR_TRANSCRIBE_TIMEOUT once `limit` passes, without waiting for `operation`, which keeps running
/// until `onTimeout` stops it. A wedged system service therefore cannot hang the caller.
private func withTimeout<T>(
    _ limit: Duration,
    onTimeout: @escaping @Sendable () async -> Void = {},
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let first = FirstResult(continuation)
        let timer = Task {
            try await Task.sleep(for: limit)
            let timeout = TranscribeFailure(code: .timeout, message: "Timed out after \(limit)")
            if first.finish(.failure(timeout)) {
                await onTimeout()
            }
        }
        Task {
            let result: Result<T, Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            timer.cancel()
            first.finish(result)
        }
    }
}

// MARK: - Audio

struct DecodedAudio {
    let buffers: [AVAudioPCMBuffer]
    let seconds: Double
}

final class MemoryAudioSource {
    let bytes: UnsafeRawPointer
    let length: Int

    init(bytes: UnsafeRawPointer, length: Int) {
        self.bytes = bytes
        self.length = length
    }

    static let readProc: AudioFile_ReadProc = { clientData, position, requestCount, buffer, actualCount in
        let source = Unmanaged<MemoryAudioSource>.fromOpaque(clientData).takeUnretainedValue()
        let length = Int64(source.length)
        let start = min(max(position, 0), length)
        let end = min(start + Int64(requestCount), length)
        let count = Int(end - start)
        if count > 0 {
            memcpy(buffer, source.bytes.advanced(by: Int(start)), count)
        }
        actualCount.pointee = UInt32(count)
        return noErr
    }

    static let getSizeProc: AudioFile_GetSizeProc = { clientData in
        Int64(Unmanaged<MemoryAudioSource>.fromOpaque(clientData).takeUnretainedValue().length)
    }
}

private let audioFileTypeHints: [AudioFileTypeID] = [
    0,
    kAudioFileAAC_ADTSType,
    kAudioFileMP3Type,
    kAudioFileM4AType,
    kAudioFileWAVEType,
]

private let decodeFrameCapacity: AVAudioFrameCount = 8192

private let maxAudioSeconds = 600

private func decodeFailure(_ status: OSStatus) -> TranscribeFailure {
    TranscribeFailure(code: .audioDecodeFailed, message: "Audio decode failed (\(status))")
}

private func openAudioFile(source: MemoryAudioSource) throws -> AudioFileID {
    let clientData = Unmanaged.passUnretained(source).toOpaque()
    var lastStatus: OSStatus = noErr
    for hint in audioFileTypeHints {
        var fileID: AudioFileID?
        lastStatus = AudioFileOpenWithCallbacks(
            clientData,
            MemoryAudioSource.readProc,
            nil,
            MemoryAudioSource.getSizeProc,
            nil,
            hint,
            &fileID
        )
        if lastStatus == noErr, let fileID = fileID {
            return fileID
        }
    }
    throw decodeFailure(lastStatus)
}

/// Decodes audio bytes into PCM buffers in the format `clientFormat` picks for the file's own format.
func decodeAudio(
    _ audio: Data,
    clientFormat: (AudioStreamBasicDescription) -> AVAudioFormat?
) throws -> DecodedAudio {
    let decoded = try audio.withUnsafeBytes { raw -> DecodedAudio in
        guard let bytes = raw.baseAddress, raw.count > 0 else {
            throw decodeFailure(kAudioFileInvalidFileError)
        }
        return try decodePcmBuffers(bytes: bytes, length: raw.count, clientFormat: clientFormat)
    }
    if decoded.buffers.isEmpty {
        throw TranscribeFailure(code: .audioDecodeFailed, message: "No audio frames decoded")
    }
    return decoded
}

private func decodePcmBuffers(
    bytes: UnsafeRawPointer,
    length: Int,
    clientFormat: (AudioStreamBasicDescription) -> AVAudioFormat?
) throws -> DecodedAudio {
    let source = MemoryAudioSource(bytes: bytes, length: length)
    return try withExtendedLifetime(source) {
        let fileID = try openAudioFile(source: source)
        defer { AudioFileClose(fileID) }

        var extFile: ExtAudioFileRef?
        var status = ExtAudioFileWrapAudioFileID(fileID, false, &extFile)
        guard status == noErr, let ext = extFile else {
            throw decodeFailure(status)
        }
        defer { ExtAudioFileDispose(ext) }

        var fileFormat = AudioStreamBasicDescription()
        var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileDataFormat, &propertySize, &fileFormat)
        guard status == noErr else {
            throw decodeFailure(status)
        }

        guard let format = clientFormat(fileFormat) else {
            throw decodeFailure(kAudio_ParamError)
        }

        status = ExtAudioFileSetProperty(
            ext,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            format.streamDescription
        )
        guard status == noErr else {
            throw decodeFailure(status)
        }

        let maxFrames = Int64(Double(maxAudioSeconds) * format.sampleRate)
        let tooLong = TranscribeFailure(code: .audioTooLong, message: "Audio exceeds \(maxAudioSeconds) seconds")

        var declaredFrames: Int64 = 0
        var framesSize = UInt32(MemoryLayout<Int64>.size)
        if ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileLengthFrames, &framesSize, &declaredFrames) == noErr,
           declaredFrames > maxFrames {
            throw tooLong
        }

        var buffers: [AVAudioPCMBuffer] = []
        var totalFrames: Int64 = 0
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: decodeFrameCapacity) else {
                throw decodeFailure(kAudio_MemFullError)
            }
            buffer.frameLength = buffer.frameCapacity
            var frames = buffer.frameCapacity
            status = ExtAudioFileRead(ext, &frames, buffer.mutableAudioBufferList)
            guard status == noErr else {
                throw decodeFailure(status)
            }
            buffer.frameLength = frames
            if frames == 0 {
                break
            }
            totalFrames += Int64(frames)
            if totalFrames > maxFrames {
                throw tooLong
            }
            buffers.append(buffer)
        }
        return DecodedAudio(buffers: buffers, seconds: Double(totalFrames) / format.sampleRate)
    }
}

private let soundWindowSeconds = 0.02
// -70 dBFS RMS. SpeechTranscriber still recognizes speech turned down by 45 dB (peaks around -63 dBFS), so this
// only catches digital silence and noise far below any recording's floor.
private let soundThreshold: Float = 0.0003
private let minSoundWindows = 5

/// Whether at least 100 ms of the audio is louder than near-digital silence. SpeechTranscriber turns digital
/// silence into a phantom word ("我" for zh_CN), so silent audio is reported as empty without running it.
func containsSound(_ buffers: [AVAudioPCMBuffer]) -> Bool {
    var loudWindows = 0
    for buffer in buffers {
        let frames = Int(buffer.frameLength)
        let window = max(1, Int(buffer.format.sampleRate * soundWindowSeconds))
        let sample: (Int) -> Float
        if let data = buffer.floatChannelData?[0] {
            sample = { data[$0] }
        } else if let data = buffer.int16ChannelData?[0] {
            sample = { Float(data[$0]) / Float(Int16.max) }
        } else {
            return true
        }
        var start = 0
        while start < frames {
            let end = min(start + window, frames)
            var sum: Float = 0
            for index in start..<end {
                let value = sample(index)
                sum += value * value
            }
            if (sum / Float(end - start)).squareRoot() >= soundThreshold {
                loudWindows += 1
                if loudWindows >= minSoundWindows {
                    return true
                }
            }
            start = end
        }
    }
    return false
}

private let unspacedLanguages: Set<String> = ["zh", "ja", "yue"]

private func isAsciiAlphanumeric(_ character: Character) -> Bool {
    character.isASCII && (character.isLetter || character.isNumber)
}

/// Joins utterances with a space, or directly for languages written without spaces unless both sides are ASCII
/// letters or digits.
func joinUtterances(_ utterances: [String], locale: Locale) -> String {
    let texts = utterances
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard let language = locale.language.languageCode?.identifier, unspacedLanguages.contains(language) else {
        return texts.joined(separator: " ")
    }
    var joined = ""
    for text in texts {
        if let last = joined.last, let first = text.first, isAsciiAlphanumeric(last), isAsciiAlphanumeric(first) {
            joined.append(" ")
        }
        joined.append(text)
    }
    return joined
}

// MARK: - SpeechAnalyzer engine (macOS 26+)

@available(macOS 26, *)
private struct AnalyzerEngine: TranscriptionEngine {
    func modelStatus(lang: String) async throws -> TranscriptionModelStatus {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: lang)) else {
            return .unsupported
        }
        switch await AssetInventory.status(forModules: [makeTranscriber(locale)]) {
        case .installed:
            return .ready
        case .supported, .downloading:
            // Assets another app already installed only need reserving for this app, which downloads nothing.
            return await isInstalledOnSystem(locale) ? .ready : .downloadRequired
        case .unsupported:
            return .unsupported
        @unknown default:
            return .unsupported
        }
    }

    func downloadModel(lang: String) async throws {
        let transcriber = makeTranscriber(try await resolveLocale(lang))
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw TranscribeFailure(code: .modelDownloadFailed, message: error.localizedDescription)
        }
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw TranscribeFailure(code: .modelDownloadFailed, message: "Model for \(lang) is still not installed")
        }
    }

    func transcribe(audio: Data, lang: String, timeout: Duration?) async throws -> String {
        let locale = try await resolveLocale(lang)
        let transcriber = makeTranscriber(locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscribeFailure(code: .failed, message: "No audio format for \(locale.identifier)")
        }
        let decoded = try decodeAudio(audio) { _ in format }
        guard containsSound(decoded.buffers) else {
            return ""
        }
        try await reserveInstalledModel(transcriber, locale: locale)

        let inputs = decoded.buffers.map { AnalyzerInput(buffer: $0) }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let utterances = try await withTimeout(
            timeout ?? defaultTranscribeTimeout(audioSeconds: decoded.seconds),
            onTimeout: { await analyzer.cancelAndFinishNow() }
        ) {
            try await Self.analyze(inputs, with: analyzer, transcriber: transcriber)
        }
        return joinUtterances(utterances, locale: locale)
    }

    /// Returns every final result. SpeechTranscriber ends an utterance at each pause.
    private static func analyze(
        _ inputs: [AnalyzerInput],
        with analyzer: SpeechAnalyzer,
        transcriber: SpeechTranscriber
    ) async throws -> [String] {
        let (sequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        for input in inputs {
            continuation.yield(input)
        }
        continuation.finish()

        async let utterances: [String] = transcriber.results.reduce(into: []) { texts, result in
            if result.isFinal {
                texts.append(String(result.text.characters))
            }
        }
        do {
            if let last = try await analyzer.analyzeSequence(sequence) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            // Ends the results stream, so the pending utterances task can return.
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return try await utterances
    }

    private func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .transcription)
    }

    private func resolveLocale(_ lang: String) async throws -> Locale {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: lang)) else {
            throw TranscribeFailure(code: .unsupportedLanguage, message: "Speech transcription does not support \(lang)")
        }
        return locale
    }

    private func isInstalledOnSystem(_ locale: Locale) async -> Bool {
        await SpeechTranscriber.installedLocales.contains { $0.identifier == locale.identifier }
    }

    /// Reserves assets that are already on disk, so the system keeps them for this app. Never downloads.
    private func reserveInstalledModel(_ transcriber: SpeechTranscriber, locale: Locale) async throws {
        if await AssetInventory.status(forModules: [transcriber]) == .installed {
            return
        }
        let notInstalled = TranscribeFailure(
            code: .modelNotInstalled,
            message: "Model for \(locale.identifier) is not installed"
        )
        guard await isInstalledOnSystem(locale) else {
            throw notInstalled
        }
        // nil means nothing to download; the locale is reserved now.
        guard try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) == nil else {
            throw notInstalled
        }
    }
}

// MARK: - SFSpeechRecognizer engine (kept for systems before macOS 26, not selected yet)

/// On-device SFSpeechRecognizer. Not selected on any system yet, see `currentEngine()`: the host needs
/// NSSpeechRecognitionUsageDescription and the user's permission first.
///
/// Known gap: it keeps only the final result, but the recognizer ends an utterance at each pause and the final
/// result holds just the last one, so long audio loses every sentence before the last pause. Collect each finished
/// utterance as TempTalk iOS does (difftim/TempTalk-iOS#847) before selecting it.
private struct SFSpeechEngine: TranscriptionEngine {
    /// Shows the system permission prompt. Kills the process when the host has no usage description.
    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    func modelStatus(lang: String) async throws -> TranscriptionModelStatus {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: lang)) else {
            return .unsupported
        }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition ? .ready : .unsupported
    }

    func downloadModel(lang: String) async throws {
        throw TranscribeFailure(code: .unsupportedLanguage, message: "The system manages SFSpeechRecognizer models")
    }

    func transcribe(audio: Data, lang: String, timeout: Duration?) async throws -> String {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .authorized else {
            throw TranscribeFailure(code: .failed, message: "Speech recognition not authorized (status: \(status.rawValue))")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: lang)) else {
            throw TranscribeFailure(code: .unsupportedLanguage, message: "SFSpeechRecognizer does not support \(lang)")
        }
        guard recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw TranscribeFailure(code: .modelNotInstalled, message: "On-device recognition unavailable for \(lang)")
        }
        let decoded = try decodeAudio(audio) {
            AVAudioFormat(standardFormatWithSampleRate: $0.mSampleRate, channels: 1)
        }
        let callbackQueue = OperationQueue()
        callbackQueue.maxConcurrentOperationCount = 1
        recognizer.queue = callbackQueue

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = true

        let task = RecognitionTaskBox()
        return try await withTimeout(
            timeout ?? defaultTranscribeTimeout(audioSeconds: decoded.seconds),
            onTimeout: { task.cancel() }
        ) {
            try await withCheckedThrowingContinuation { continuation in
                let first = FirstResult(continuation)
                task.set(recognizer.recognitionTask(with: request) { result, error in
                    if let error = error {
                        first.finish(.failure(TranscribeFailure(code: .failed, message: error.localizedDescription)))
                    } else if let result = result, result.isFinal {
                        first.finish(.success(result.bestTranscription.formattedString))
                    }
                })
                for buffer in decoded.buffers {
                    request.append(buffer)
                }
                request.endAudio()
            }
        }
    }

    private final class RecognitionTaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: SFSpeechRecognitionTask?

        func set(_ task: SFSpeechRecognitionTask) {
            lock.lock()
            self.task = task
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }
}
