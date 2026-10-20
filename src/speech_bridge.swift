import AudioToolbox
import AVFAudio
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

/// Returns bit flags for the requested locale:
/// bit 0 = recognizer available, bit 1 = on-device recognition supported,
/// bit 2 = speech permission granted.
@_cdecl("speech_recognition_capabilities_ffi")
public func speechRecognitionCapabilitiesFfi(_ langPtr: UnsafePointer<CChar>) -> UInt32 {
    let locale = Locale(identifier: String(cString: langPtr))
    guard let recognizer = SFSpeechRecognizer(locale: locale) else {
        return 0
    }

    var capabilities: UInt32 = 0
    if recognizer.isAvailable {
        capabilities |= 1
    }
    if recognizer.supportsOnDeviceRecognition {
        capabilities |= 1 << 1
    }
    if SFSpeechRecognizer.authorizationStatus() == .authorized {
        capabilities |= 1 << 2
    }
    return capabilities
}

struct SpeechBridgeError: Error {
    let message: String
}

struct AudioDecodeError: Error {
    let status: OSStatus
}

func makeRecognizer(lang: String, onDeviceOnly: Bool) -> Result<SFSpeechRecognizer, SpeechBridgeError> {
    let authStatus = SFSpeechRecognizer.authorizationStatus()
    guard authStatus == .authorized else {
        return .failure(SpeechBridgeError(message: "Speech recognition not authorized (status: \(authStatus.rawValue)). Call requestSpeechPermission() first."))
    }

    let locale = Locale(identifier: lang)
    guard let recognizer = SFSpeechRecognizer(locale: locale) else {
        return .failure(SpeechBridgeError(message: "SFSpeechRecognizer could not be created for locale: \(lang)"))
    }
    guard recognizer.isAvailable else {
        return .failure(SpeechBridgeError(message: "Speech recognizer is not available for locale: \(lang)"))
    }
    if onDeviceOnly && !recognizer.supportsOnDeviceRecognition {
        return .failure(SpeechBridgeError(message: "On-device speech recognition is not available for locale: \(lang)"))
    }
    let callbackQueue = OperationQueue()
    callbackQueue.maxConcurrentOperationCount = 1
    recognizer.queue = callbackQueue
    return .success(recognizer)
}

func runRecognition(
    recognizer: SFSpeechRecognizer,
    request: SFSpeechRecognitionRequest,
    feed: (() -> Void)?
) -> String {
    var result = "__error__:unknown"
    let sema = DispatchSemaphore(value: 0)
    var signaled = false

    func signal(_ value: String) {
        guard !signaled else { return }
        signaled = true
        result = value
        sema.signal()
    }

    recognizer.recognitionTask(with: request) { speechResult, error in
        if let error = error {
            signal("__error__:\(error.localizedDescription)")
        } else if let speechResult = speechResult, speechResult.isFinal {
            signal(speechResult.bestTranscription.formattedString)
        }
    }
    feed?()

    withExtendedLifetime(recognizer) { sema.wait() }
    return result
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
    throw AudioDecodeError(status: lastStatus)
}

func decodePcmBuffers(bytes: UnsafeRawPointer, length: Int) throws -> (format: AVAudioFormat, buffers: [AVAudioPCMBuffer]) {
    let source = MemoryAudioSource(bytes: bytes, length: length)
    return try withExtendedLifetime(source) {
        let fileID = try openAudioFile(source: source)
        defer { AudioFileClose(fileID) }

        var extFile: ExtAudioFileRef?
        var status = ExtAudioFileWrapAudioFileID(fileID, false, &extFile)
        guard status == noErr, let ext = extFile else {
            throw AudioDecodeError(status: status)
        }
        defer { ExtAudioFileDispose(ext) }

        var fileFormat = AudioStreamBasicDescription()
        var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileDataFormat, &propertySize, &fileFormat)
        guard status == noErr else {
            throw AudioDecodeError(status: status)
        }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: fileFormat.mSampleRate, channels: 1) else {
            throw AudioDecodeError(status: kAudio_ParamError)
        }

        status = ExtAudioFileSetProperty(
            ext,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            format.streamDescription
        )
        guard status == noErr else {
            throw AudioDecodeError(status: status)
        }

        let maxFrames = Int64(Double(maxAudioSeconds) * format.sampleRate)
        let tooLong = SpeechBridgeError(message: "Audio exceeds \(maxAudioSeconds) seconds")

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
                throw AudioDecodeError(status: kAudio_MemFullError)
            }
            buffer.frameLength = buffer.frameCapacity
            var frames = buffer.frameCapacity
            status = ExtAudioFileRead(ext, &frames, buffer.mutableAudioBufferList)
            guard status == noErr else {
                throw AudioDecodeError(status: status)
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
        return (format, buffers)
    }
}

/// Recognize speech, optionally rejecting any recognition that cannot run locally.
@_cdecl("recognize_speech_with_options_ffi")
public func recognizeSpeechWithOptionsFfi(
    filePathPtr: UnsafePointer<CChar>,
    langPtr: UnsafePointer<CChar>,
    onDeviceOnly: Bool
) -> UnsafeMutablePointer<CChar>? {
    let filePath = String(cString: filePathPtr)
    let lang = String(cString: langPtr)

    let recognizer: SFSpeechRecognizer
    switch makeRecognizer(lang: lang, onDeviceOnly: onDeviceOnly) {
    case .success(let value): recognizer = value
    case .failure(let error): return strdup("__error__:\(error.message)")
    }

    let url = URL(fileURLWithPath: filePath)
    let request = SFSpeechURLRecognitionRequest(url: url)
    request.shouldReportPartialResults = false
    request.addsPunctuation = true
    request.requiresOnDeviceRecognition = onDeviceOnly

    return strdup(runRecognition(recognizer: recognizer, request: request, feed: nil))
}

@_cdecl("recognize_speech_buffer_ffi")
public func recognizeSpeechBufferFfi(
    bytes: UnsafePointer<UInt8>,
    length: Int,
    langPtr: UnsafePointer<CChar>,
    onDeviceOnly: Bool
) -> UnsafeMutablePointer<CChar>? {
    let lang = String(cString: langPtr)

    let recognizer: SFSpeechRecognizer
    switch makeRecognizer(lang: lang, onDeviceOnly: onDeviceOnly) {
    case .success(let value): recognizer = value
    case .failure(let error): return strdup("__error__:\(error.message)")
    }

    let buffers: [AVAudioPCMBuffer]
    do {
        buffers = try decodePcmBuffers(bytes: UnsafeRawPointer(bytes), length: length).buffers
    } catch let error as SpeechBridgeError {
        return strdup("__error__:\(error.message)")
    } catch {
        let status = (error as? AudioDecodeError)?.status ?? kAudio_ParamError
        return strdup("__error__:Audio decode failed (\(status))")
    }

    if buffers.allSatisfy({ $0.frameLength == 0 }) {
        return strdup("__error__:No audio frames decoded")
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = false
    request.addsPunctuation = true
    request.requiresOnDeviceRecognition = onDeviceOnly

    return strdup(runRecognition(recognizer: recognizer, request: request) {
        for buffer in buffers {
            request.append(buffer)
        }
        request.endAudio()
    })
}

@_cdecl("free_speech_result")
public func freeSpeechResult(_ ptr: UnsafeMutablePointer<CChar>?) {
    free(ptr)
}
