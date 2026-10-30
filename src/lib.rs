#![deny(clippy::all)]

use napi::bindgen_prelude::*;
use napi::JsObject;
use napi_derive::napi;
use std::ffi::{CStr, CString};

// ── FFI declarations ──────────────────────────────────────────────────────────

#[allow(improper_ctypes)]
extern "C" {
    fn translate_text_ffi(text: *const i8, target_lang: *const i8) -> *mut i8;
    fn free_translate_result(ptr: *mut i8);
    fn is_translate_text_support_ffi() -> bool;

    fn is_transcribe_audio_support_ffi() -> bool;
    fn transcribe_audio_model_status_ffi(lang: *const i8) -> *mut i8;
    fn download_transcribe_audio_model_ffi(lang: *const i8) -> *mut i8;
    fn transcribe_audio_ffi(
        bytes: *const u8,
        len: usize,
        lang: *const i8,
        timeout_ms: u32,
    ) -> *mut i8;
    fn free_speech_result(ptr: *mut i8);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn cstring(s: &str) -> Result<CString> {
    CString::new(s).map_err(|e| Error::from_reason(e.to_string()))
}

const ERROR_PREFIX: &str = "__error__:";

#[derive(Debug)]
struct CodedFailure {
    code: String,
    message: String,
}

/// Splits a Swift result into its value or its "__error__:<code>:<message>" failure.
/// Codes outside `known` become `fallback`.
fn decode_coded_result(
    result: String,
    known: &[&str],
    fallback: &str,
) -> std::result::Result<String, CodedFailure> {
    let Some(payload) = result.strip_prefix(ERROR_PREFIX) else {
        return Ok(result);
    };

    let Some((code, message)) = payload.split_once(':') else {
        return Err(CodedFailure {
            code: fallback.to_string(),
            message: payload.to_string(),
        });
    };

    let code = if known.contains(&code) {
        code
    } else {
        fallback
    };

    Err(CodedFailure {
        code: code.to_string(),
        message: message.to_string(),
    })
}

/// A JS Error whose `code` property is the failure's code.
fn coded_error(env: Env, failure: CodedFailure) -> Error {
    let coded_error: napi::Error<String> = napi::Error::new(failure.code, failure.message);
    let js_error = napi::JsError::from(coded_error).into_unknown(env);
    Error::from(js_error)
}

// ── translateText ─────────────────────────────────────────────────────────────

const ERR_TRANSLATE_UNSUPPORTED_OS_VERSION: &str = "ERR_TRANSLATE_UNSUPPORTED_OS_VERSION";
const ERR_TRANSLATE_LANGUAGE_PAIR_NOT_INSTALLED: &str = "ERR_TRANSLATE_LANGUAGE_PAIR_NOT_INSTALLED";
const ERR_TRANSLATE_LANGUAGE_PAIR_NOT_READY: &str = "ERR_TRANSLATE_LANGUAGE_PAIR_NOT_READY";
const ERR_TRANSLATE_FAILED: &str = "ERR_TRANSLATE_FAILED";

const TRANSLATE_ERROR_CODES: &[&str] = &[
    ERR_TRANSLATE_UNSUPPORTED_OS_VERSION,
    ERR_TRANSLATE_LANGUAGE_PAIR_NOT_INSTALLED,
    ERR_TRANSLATE_LANGUAGE_PAIR_NOT_READY,
    ERR_TRANSLATE_FAILED,
];

#[allow(non_camel_case_types)]
#[napi(string_enum)]
pub enum TranslateErrorCode {
    #[napi(value = "ERR_TRANSLATE_UNSUPPORTED_OS_VERSION")]
    UNSUPPORT_OS_VERSION,
    #[napi(value = "ERR_TRANSLATE_LANGUAGE_PAIR_NOT_INSTALLED")]
    LANGUAGE_PAIR_NOT_INSTALLED,
    #[napi(value = "ERR_TRANSLATE_LANGUAGE_PAIR_NOT_READY")]
    LANGUAGE_PAIR_NOT_READY,
    #[napi(value = "ERR_TRANSLATE_FAILED")]
    FAILED,
}

fn decode_translate_result(result: String) -> std::result::Result<String, CodedFailure> {
    decode_coded_result(result, TRANSLATE_ERROR_CODES, ERR_TRANSLATE_FAILED)
}

pub struct TranslateTask {
    text: String,
    target_lang: String,
    failure_code: Option<String>,
}

impl Task for TranslateTask {
    type Output = String;
    type JsValue = String;

    fn compute(&mut self) -> Result<Self::Output> {
        let c_text = cstring(&self.text)?;
        let c_lang = cstring(&self.target_lang)?;

        let ptr = unsafe { translate_text_ffi(c_text.as_ptr(), c_lang.as_ptr()) };
        if ptr.is_null() {
            return Err(Error::from_reason("translate_text_ffi returned null"));
        }
        let result = unsafe { CStr::from_ptr(ptr).to_string_lossy().into_owned() };
        unsafe { free_translate_result(ptr) };

        match decode_translate_result(result) {
            Ok(translated_text) => Ok(translated_text),
            Err(failure) => {
                self.failure_code = Some(failure.code);
                Err(Error::from_reason(failure.message))
            }
        }
    }

    fn resolve(&mut self, _env: Env, output: Self::Output) -> Result<Self::JsValue> {
        Ok(output)
    }

    fn reject(&mut self, env: Env, err: Error) -> Result<Self::JsValue> {
        let code = self
            .failure_code
            .take()
            .unwrap_or_else(|| ERR_TRANSLATE_FAILED.to_string());
        Err(coded_error(
            env,
            CodedFailure {
                code,
                message: err.reason,
            },
        ))
    }
}

/// Translate text with the system's installed language models.
///
/// Rejects with an Error whose code is one of:
/// `ERR_TRANSLATE_UNSUPPORTED_OS_VERSION`,
/// `ERR_TRANSLATE_LANGUAGE_PAIR_NOT_INSTALLED`, `ERR_TRANSLATE_LANGUAGE_PAIR_NOT_READY`,
/// or `ERR_TRANSLATE_FAILED`.
#[napi(ts_return_type = "Promise<string>")]
pub fn translate_text(text: String, target_lang: String) -> AsyncTask<TranslateTask> {
    AsyncTask::new(TranslateTask {
        text,
        target_lang,
        failure_code: None,
    })
}

/// Check whether the current macOS version supports headless local translation.
#[napi]
pub fn is_translate_text_support() -> bool {
    unsafe { is_translate_text_support_ffi() }
}

// ── Speech transcription ──────────────────────────────────────────────────────

const ERR_TRANSCRIBE_UNSUPPORTED_OS_VERSION: &str = "ERR_TRANSCRIBE_UNSUPPORTED_OS_VERSION";
const ERR_TRANSCRIBE_UNSUPPORTED_LANGUAGE: &str = "ERR_TRANSCRIBE_UNSUPPORTED_LANGUAGE";
const ERR_TRANSCRIBE_MODEL_NOT_INSTALLED: &str = "ERR_TRANSCRIBE_MODEL_NOT_INSTALLED";
const ERR_TRANSCRIBE_MODEL_DOWNLOAD_FAILED: &str = "ERR_TRANSCRIBE_MODEL_DOWNLOAD_FAILED";
const ERR_TRANSCRIBE_AUDIO_DECODE_FAILED: &str = "ERR_TRANSCRIBE_AUDIO_DECODE_FAILED";
const ERR_TRANSCRIBE_AUDIO_TOO_LONG: &str = "ERR_TRANSCRIBE_AUDIO_TOO_LONG";
const ERR_TRANSCRIBE_TIMEOUT: &str = "ERR_TRANSCRIBE_TIMEOUT";
const ERR_TRANSCRIBE_FAILED: &str = "ERR_TRANSCRIBE_FAILED";

const TRANSCRIBE_ERROR_CODES: &[&str] = &[
    ERR_TRANSCRIBE_UNSUPPORTED_OS_VERSION,
    ERR_TRANSCRIBE_UNSUPPORTED_LANGUAGE,
    ERR_TRANSCRIBE_MODEL_NOT_INSTALLED,
    ERR_TRANSCRIBE_MODEL_DOWNLOAD_FAILED,
    ERR_TRANSCRIBE_AUDIO_DECODE_FAILED,
    ERR_TRANSCRIBE_AUDIO_TOO_LONG,
    ERR_TRANSCRIBE_TIMEOUT,
    ERR_TRANSCRIBE_FAILED,
];

#[allow(non_camel_case_types)]
#[napi(string_enum)]
pub enum TranscribeErrorCode {
    #[napi(value = "ERR_TRANSCRIBE_UNSUPPORTED_OS_VERSION")]
    UNSUPPORTED_OS_VERSION,
    #[napi(value = "ERR_TRANSCRIBE_UNSUPPORTED_LANGUAGE")]
    UNSUPPORTED_LANGUAGE,
    #[napi(value = "ERR_TRANSCRIBE_MODEL_NOT_INSTALLED")]
    MODEL_NOT_INSTALLED,
    #[napi(value = "ERR_TRANSCRIBE_MODEL_DOWNLOAD_FAILED")]
    MODEL_DOWNLOAD_FAILED,
    #[napi(value = "ERR_TRANSCRIBE_AUDIO_DECODE_FAILED")]
    AUDIO_DECODE_FAILED,
    #[napi(value = "ERR_TRANSCRIBE_AUDIO_TOO_LONG")]
    AUDIO_TOO_LONG,
    #[napi(value = "ERR_TRANSCRIBE_TIMEOUT")]
    TIMEOUT,
    #[napi(value = "ERR_TRANSCRIBE_FAILED")]
    FAILED,
}

/// Copies and frees a C string returned by the speech bridge.
///
/// # Safety
///
/// `ptr` must be null or a string the speech bridge allocated.
unsafe fn take_speech_result(ptr: *mut i8) -> String {
    if ptr.is_null() {
        return format!("{ERROR_PREFIX}{ERR_TRANSCRIBE_FAILED}:speech bridge returned null");
    }
    let result = CStr::from_ptr(ptr).to_string_lossy().into_owned();
    free_speech_result(ptr);
    result
}

/// Runs `work` on a thread of its own and settles the returned promise with its result.
/// The speech bridge blocks until the system answers, which for a model download takes
/// minutes, so it must not hold one of libuv's few pool threads.
fn spawn_speech_work<T, F>(env: Env, work: F, into_value: fn(String) -> T) -> Result<JsObject>
where
    T: ToNapiValue + Send + 'static,
    F: FnOnce() -> String + Send + 'static,
{
    let (deferred, promise) = env.create_deferred()?;
    std::thread::Builder::new()
        .name("local-transcribe".to_string())
        .spawn(move || {
            let result = decode_coded_result(work(), TRANSCRIBE_ERROR_CODES, ERR_TRANSCRIBE_FAILED);
            deferred.resolve(move |env| match result {
                Ok(value) => Ok(into_value(value)),
                Err(failure) => Err(coded_error(env, failure)),
            });
        })
        .map_err(|e| Error::from_reason(e.to_string()))?;
    Ok(promise)
}

/// Check whether this system can transcribe speech at all. Languages and models are not checked.
#[napi]
pub fn is_transcribe_audio_support() -> bool {
    unsafe { is_transcribe_audio_support_ffi() }
}

/// Check whether the model for `lang` (for example "zh-CN" or "en-US") is ready.
/// Never downloads anything or asks for permission.
#[napi(ts_return_type = "Promise<'ready' | 'downloadRequired' | 'unsupported'>")]
pub fn get_transcribe_audio_model_status(env: Env, lang: String) -> Result<JsObject> {
    let c_lang = cstring(&lang)?;
    spawn_speech_work(
        env,
        move || unsafe { take_speech_result(transcribe_audio_model_status_ffi(c_lang.as_ptr())) },
        |status| status,
    )
}

/// Download and install the model for `lang`. Resolves once it is installed.
#[napi(ts_return_type = "Promise<void>")]
pub fn download_transcribe_audio_model(env: Env, lang: String) -> Result<JsObject> {
    let c_lang = cstring(&lang)?;
    spawn_speech_work(
        env,
        move || unsafe { take_speech_result(download_transcribe_audio_model_ffi(c_lang.as_ptr())) },
        |_| (),
    )
}

#[napi(object)]
pub struct TranscribeAudioOptions {
    /// Give up after this many milliseconds. Defaults to 30 seconds plus the audio's length.
    pub timeout_ms: Option<u32>,
}

/// Transcribe in-memory audio (mp3 / m4a / adts / wav, up to 10 minutes) on device.
/// Resolves "" when the audio holds no speech.
#[napi(ts_return_type = "Promise<string>")]
pub fn transcribe_audio(
    env: Env,
    audio: Uint8Array,
    lang: String,
    options: Option<TranscribeAudioOptions>,
) -> Result<JsObject> {
    let audio = audio.to_vec();
    let c_lang = cstring(&lang)?;
    let timeout_ms = options.and_then(|options| options.timeout_ms).unwrap_or(0);
    spawn_speech_work(
        env,
        move || unsafe {
            take_speech_result(transcribe_audio_ffi(
                audio.as_ptr(),
                audio.len(),
                c_lang.as_ptr(),
                timeout_ms,
            ))
        },
        |text| text,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_unsupported_os_translation_error() {
        let failure = decode_translate_result(
            "__error__:ERR_TRANSLATE_UNSUPPORTED_OS_VERSION:Translation.framework requires macOS 26+"
                .to_string(),
        )
        .unwrap_err();

        assert_eq!(failure.code, "ERR_TRANSLATE_UNSUPPORTED_OS_VERSION");
        assert_eq!(failure.message, "Translation.framework requires macOS 26+");
    }

    #[test]
    fn decodes_missing_language_pair_translation_error() {
        let failure = decode_translate_result(
            "__error__:ERR_TRANSLATE_LANGUAGE_PAIR_NOT_INSTALLED:No installed language pair for target: zh-Hans"
                .to_string(),
        )
        .unwrap_err();

        assert_eq!(failure.code, "ERR_TRANSLATE_LANGUAGE_PAIR_NOT_INSTALLED");
        assert_eq!(
            failure.message,
            "No installed language pair for target: zh-Hans"
        );
    }

    #[test]
    fn decodes_not_ready_language_pair_translation_error() {
        let failure = decode_translate_result(
            "__error__:ERR_TRANSLATE_LANGUAGE_PAIR_NOT_READY:Language availability for target en was not ready within 2.0 seconds"
                .to_string(),
        )
        .unwrap_err();

        assert_eq!(failure.code, "ERR_TRANSLATE_LANGUAGE_PAIR_NOT_READY");
    }

    #[test]
    fn malformed_translation_error_falls_back_to_generic_code() {
        let failure = decode_translate_result("__error__:unexpected framework failure".to_string())
            .unwrap_err();

        assert_eq!(failure.code, "ERR_TRANSLATE_FAILED");
        assert_eq!(failure.message, "unexpected framework failure");
    }

    #[test]
    fn decodes_transcribe_error() {
        let failure = decode_coded_result(
            "__error__:ERR_TRANSCRIBE_MODEL_NOT_INSTALLED:Model for zh_CN is not installed"
                .to_string(),
            TRANSCRIBE_ERROR_CODES,
            ERR_TRANSCRIBE_FAILED,
        )
        .unwrap_err();

        assert_eq!(failure.code, "ERR_TRANSCRIBE_MODEL_NOT_INSTALLED");
        assert_eq!(failure.message, "Model for zh_CN is not installed");
    }

    #[test]
    fn unknown_transcribe_error_falls_back_to_generic_code() {
        let failure = decode_coded_result(
            "__error__:ERR_TRANSLATE_FAILED:wrong family".to_string(),
            TRANSCRIBE_ERROR_CODES,
            ERR_TRANSCRIBE_FAILED,
        )
        .unwrap_err();

        assert_eq!(failure.code, "ERR_TRANSCRIBE_FAILED");
    }

    #[test]
    fn transcript_passes_through() {
        assert_eq!(
            decode_coded_result(
                "你好。".to_string(),
                TRANSCRIBE_ERROR_CODES,
                ERR_TRANSCRIBE_FAILED
            )
            .unwrap(),
            "你好。"
        );
    }

    #[test]
    fn exposes_swift_transcribe_audio_support() {
        let ffi_result = unsafe { is_transcribe_audio_support_ffi() };
        assert_eq!(is_transcribe_audio_support(), ffi_result);
    }

    #[test]
    fn exposes_swift_translate_text_support() {
        let ffi_result = unsafe { is_translate_text_support_ffi() };
        assert_eq!(is_translate_text_support(), ffi_result);
    }
}
