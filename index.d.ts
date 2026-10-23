export type { SpeechRecognitionCapabilities, SpeechRecognitionOptions } from './binding'

export declare enum TranslateErrorCode {
  UNSUPPORTED_PLATFORM = 'ERR_TRANSLATE_UNSUPPORTED_PLATFORM',
  UNSUPPORT_OS_VERSION = 'ERR_TRANSLATE_UNSUPPORTED_OS_VERSION',
  LANGUAGE_PAIR_NOT_INSTALLED = 'ERR_TRANSLATE_LANGUAGE_PAIR_NOT_INSTALLED',
  LANGUAGE_PAIR_NOT_READY = 'ERR_TRANSLATE_LANGUAGE_PAIR_NOT_READY',
  FAILED = 'ERR_TRANSLATE_FAILED'
}

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
 * Request authorization to use speech recognition.
 * Returns "authorized" | "denied" | "restricted" | "notDetermined".
 * Rejects with `ERR_TRANSLATE_UNSUPPORTED_PLATFORM` when the native addon is unavailable.
 */
export declare function requestSpeechPermission(): Promise<string>
/**
 * Recognize speech from an audio file, optionally requiring the system's local model.
 * Rejects with `ERR_TRANSLATE_UNSUPPORTED_PLATFORM` when the native addon is unavailable.
 */
export declare function recognizeSpeech(
  filePath: string,
  lang: string,
  options?: import('./binding').SpeechRecognitionOptions | undefined | null
): Promise<string>
/**
 * Recognize speech from in-memory audio data (mp3 / m4a / adts / wav), optionally requiring the system's local model.
 * Rejects with `ERR_TRANSLATE_UNSUPPORTED_PLATFORM` when the native addon is unavailable.
 */
export declare function recognizeSpeechBuffer(
  audio: Uint8Array,
  lang: string,
  options?: import('./binding').SpeechRecognitionOptions | undefined | null
): Promise<string>
/** Check whether the selected locale currently supports system speech recognition. */
export declare function getSpeechRecognitionCapabilities(lang: string): import('./binding').SpeechRecognitionCapabilities
/**
 * Check whether `recognizeSpeech` / `recognizeSpeechBuffer` can run for the locale and options.
 * Authorization is not checked; use `requestSpeechPermission` for that.
 */
export declare function isRecognizeSpeechSupport(
  lang: string,
  options?: import('./binding').SpeechRecognitionOptions | undefined | null
): boolean
