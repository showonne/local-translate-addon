export type { TranscribeAudioOptions } from './binding'

export declare enum TranslateErrorCode {
  UNSUPPORTED_PLATFORM = 'ERR_TRANSLATE_UNSUPPORTED_PLATFORM',
  UNSUPPORT_OS_VERSION = 'ERR_TRANSLATE_UNSUPPORTED_OS_VERSION',
  LANGUAGE_PAIR_NOT_INSTALLED = 'ERR_TRANSLATE_LANGUAGE_PAIR_NOT_INSTALLED',
  LANGUAGE_PAIR_NOT_READY = 'ERR_TRANSLATE_LANGUAGE_PAIR_NOT_READY',
  FAILED = 'ERR_TRANSLATE_FAILED'
}

export declare enum TranscribeErrorCode {
  UNSUPPORTED_PLATFORM = 'ERR_TRANSCRIBE_UNSUPPORTED_PLATFORM',
  UNSUPPORTED_OS_VERSION = 'ERR_TRANSCRIBE_UNSUPPORTED_OS_VERSION',
  UNSUPPORTED_LANGUAGE = 'ERR_TRANSCRIBE_UNSUPPORTED_LANGUAGE',
  MODEL_NOT_INSTALLED = 'ERR_TRANSCRIBE_MODEL_NOT_INSTALLED',
  MODEL_DOWNLOAD_FAILED = 'ERR_TRANSCRIBE_MODEL_DOWNLOAD_FAILED',
  AUDIO_DECODE_FAILED = 'ERR_TRANSCRIBE_AUDIO_DECODE_FAILED',
  AUDIO_TOO_LONG = 'ERR_TRANSCRIBE_AUDIO_TOO_LONG',
  TIMEOUT = 'ERR_TRANSCRIBE_TIMEOUT',
  FAILED = 'ERR_TRANSCRIBE_FAILED'
}

export type TranscribeAudioModelStatus = 'ready' | 'downloadRequired' | 'unsupported'

/**
 * Translate text with the system's installed language models.
 *
 * Rejects with an Error whose code is one of:
 * `ERR_TRANSLATE_UNSUPPORTED_PLATFORM`, `ERR_TRANSLATE_UNSUPPORTED_OS_VERSION`,
 * `ERR_TRANSLATE_LANGUAGE_PAIR_NOT_INSTALLED`, `ERR_TRANSLATE_LANGUAGE_PAIR_NOT_READY`,
 * or `ERR_TRANSLATE_FAILED`.
 */
export declare function translateText(text: string, targetLang: string): Promise<string>
/** Check whether the current platform supports headless local translation. */
export declare function isTranslateTextSupport(): boolean
/**
 * Check whether this system can transcribe speech on device at all (macOS 26+).
 * Languages and models are not checked; use `getTranscribeAudioModelStatus` for those.
 */
export declare function isTranscribeAudioSupport(): boolean
/**
 * Check whether the model for `lang` (a full locale such as "zh-CN" or "en-US") is ready.
 * Never downloads anything or asks for permission. Resolves "unsupported" when the native addon is unavailable.
 */
export declare function getTranscribeAudioModelStatus(lang: string): Promise<TranscribeAudioModelStatus>
/**
 * Download and install the model for `lang` (several hundred MB). Resolves once it is installed.
 * Rejects with a `TranscribeErrorCode`.
 */
export declare function downloadTranscribeAudioModel(lang: string): Promise<void>
/**
 * Transcribe in-memory audio (mp3 / m4a / adts / wav, up to 10 minutes) on device.
 * Resolves "" when the audio holds no speech. Rejects with a `TranscribeErrorCode`;
 * `ERR_TRANSCRIBE_MODEL_NOT_INSTALLED` means `downloadTranscribeAudioModel` has to run first.
 */
export declare function transcribeAudio(
  audio: Uint8Array,
  lang: string,
  options?: import('./binding').TranscribeAudioOptions | undefined | null
): Promise<string>
