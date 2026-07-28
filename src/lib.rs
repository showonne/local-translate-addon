#![deny(clippy::all)]

use napi::bindgen_prelude::*;
use napi_derive::napi;
use std::ffi::{CStr, CString};

// ── FFI declarations ──────────────────────────────────────────────────────────

#[allow(improper_ctypes)]
extern "C" {
    fn translate_text_ffi(text: *const i8, target_lang: *const i8) -> *mut i8;
    fn free_translate_result(ptr: *mut i8);

    fn recognize_speech_with_options_ffi(
        file_path: *const i8,
        lang: *const i8,
        on_device_only: bool,
    ) -> *mut i8;
    fn speech_recognition_capabilities_ffi(lang: *const i8) -> u32;
    fn request_speech_permission_ffi() -> *mut i8;
    fn free_speech_result(ptr: *mut i8);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn cstring(s: &str) -> Result<CString> {
    CString::new(s).map_err(|e| Error::from_reason(e.to_string()))
}

// ── translateText ─────────────────────────────────────────────────────────────

const TRANSLATE_ERROR_PREFIX: &str = "__error__:";
const ERR_TRANSLATE_UNSUPPORTED_OS_VERSION: &str = "ERR_TRANSLATE_UNSUPPORTED_OS_VERSION";
const ERR_TRANSLATE_LANGUAGE_PAIR_NOT_INSTALLED: &str = "ERR_TRANSLATE_LANGUAGE_PAIR_NOT_INSTALLED";
const ERR_TRANSLATE_FAILED: &str = "ERR_TRANSLATE_FAILED";

#[allow(non_camel_case_types)]
#[napi(string_enum)]
pub enum TranslateErrorCode {
    #[napi(value = "ERR_TRANSLATE_UNSUPPORTED_OS_VERSION")]
    UNSUPPORT_OS_VERSION,
    #[napi(value = "ERR_TRANSLATE_LANGUAGE_PAIR_NOT_INSTALLED")]
    LANGUAGE_PAIR_NOT_INSTALLED,
    #[napi(value = "ERR_TRANSLATE_FAILED")]
    FAILED,
}

#[derive(Debug)]
struct TranslateFailure {
    code: String,
    message: String,
}

fn decode_translate_result(result: String) -> std::result::Result<String, TranslateFailure> {
    let Some(payload) = result.strip_prefix(TRANSLATE_ERROR_PREFIX) else {
        return Ok(result);
    };

    let Some((code, message)) = payload.split_once(':') else {
        return Err(TranslateFailure {
            code: ERR_TRANSLATE_FAILED.to_string(),
            message: payload.to_string(),
        });
    };

    let code = match code {
        ERR_TRANSLATE_UNSUPPORTED_OS_VERSION => ERR_TRANSLATE_UNSUPPORTED_OS_VERSION,
        ERR_TRANSLATE_LANGUAGE_PAIR_NOT_INSTALLED => ERR_TRANSLATE_LANGUAGE_PAIR_NOT_INSTALLED,
        ERR_TRANSLATE_FAILED => ERR_TRANSLATE_FAILED,
        _ => ERR_TRANSLATE_FAILED,
    };

    Err(TranslateFailure {
        code: code.to_string(),
        message: message.to_string(),
    })
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
        let coded_error: napi::Error<String> = napi::Error::new(code, err.reason);
        let js_error = napi::JsError::from(coded_error).into_unknown(env);
        Err(Error::from(js_error))
    }
}

/// Translate text with the system's installed language models.
///
/// Rejects with an Error whose code is one of:
/// `ERR_TRANSLATE_UNSUPPORTED_OS_VERSION`,
/// `ERR_TRANSLATE_LANGUAGE_PAIR_NOT_INSTALLED`, or `ERR_TRANSLATE_FAILED`.
#[napi]
pub fn translate_text(text: String, target_lang: String) -> AsyncTask<TranslateTask> {
    AsyncTask::new(TranslateTask {
        text,
        target_lang,
        failure_code: None,
    })
}

// ── requestSpeechPermission ───────────────────────────────────────────────────

pub struct RequestSpeechPermissionTask;

impl Task for RequestSpeechPermissionTask {
    type Output = String;
    type JsValue = String;

    fn compute(&mut self) -> Result<Self::Output> {
        let ptr = unsafe { request_speech_permission_ffi() };
        if ptr.is_null() {
            return Err(Error::from_reason("request_speech_permission_ffi returned null"));
        }
        let result = unsafe { CStr::from_ptr(ptr).to_string_lossy().into_owned() };
        unsafe { free_speech_result(ptr) };
        Ok(result)
    }

    fn resolve(&mut self, _env: Env, output: Self::Output) -> Result<Self::JsValue> {
        Ok(output)
    }
}

/// Request authorization to use speech recognition.
/// Returns "authorized" | "denied" | "restricted" | "notDetermined".
#[napi]
pub fn request_speech_permission() -> AsyncTask<RequestSpeechPermissionTask> {
    AsyncTask::new(RequestSpeechPermissionTask)
}

// ── recognizeSpeech ───────────────────────────────────────────────────────────

pub struct RecognizeSpeechTask {
    file_path: String,
    lang: String,
    on_device_only: bool,
}

impl Task for RecognizeSpeechTask {
    type Output = String;
    type JsValue = String;

    fn compute(&mut self) -> Result<Self::Output> {
        let c_path = cstring(&self.file_path)?;
        let c_lang = cstring(&self.lang)?;

        let ptr = unsafe {
            recognize_speech_with_options_ffi(
                c_path.as_ptr(),
                c_lang.as_ptr(),
                self.on_device_only,
            )
        };
        if ptr.is_null() {
            return Err(Error::from_reason("recognize_speech_ffi returned null"));
        }
        let result = unsafe { CStr::from_ptr(ptr).to_string_lossy().into_owned() };
        unsafe { free_speech_result(ptr) };

        if let Some(msg) = result.strip_prefix("__error__:") {
            Err(Error::from_reason(msg.to_string()))
        } else {
            Ok(result)
        }
    }

    fn resolve(&mut self, _env: Env, output: Self::Output) -> Result<Self::JsValue> {
        Ok(output)
    }
}

#[napi(object)]
pub struct SpeechRecognitionOptions {
    pub on_device_only: Option<bool>,
}

/// Recognize speech from an audio file, optionally requiring the system's local model.
#[napi]
pub fn recognize_speech(
    file_path: String,
    lang: String,
    options: Option<SpeechRecognitionOptions>,
) -> AsyncTask<RecognizeSpeechTask> {
    AsyncTask::new(RecognizeSpeechTask {
        file_path,
        lang,
        on_device_only: options.and_then(|options| options.on_device_only).unwrap_or(false),
    })
}

#[napi(object)]
pub struct SpeechRecognitionCapabilities {
    pub is_available: bool,
    pub supports_on_device_recognition: bool,
    pub is_authorized: bool,
}

/// Check whether the selected locale currently supports system speech recognition.
#[napi]
pub fn get_speech_recognition_capabilities(
    lang: String,
) -> Result<SpeechRecognitionCapabilities> {
    let c_lang = cstring(&lang)?;
    let capabilities = unsafe { speech_recognition_capabilities_ffi(c_lang.as_ptr()) };
    Ok(SpeechRecognitionCapabilities {
        is_available: capabilities & 1 != 0,
        supports_on_device_recognition: capabilities & (1 << 1) != 0,
        is_authorized: capabilities & (1 << 2) != 0,
    })
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
            "__error__:ERR_TRANSLATE_LANGUAGE_PAIR_NOT_INSTALLED:No installed language pair found for target: zh-Hans"
                .to_string(),
        )
        .unwrap_err();

        assert_eq!(failure.code, "ERR_TRANSLATE_LANGUAGE_PAIR_NOT_INSTALLED");
        assert_eq!(
            failure.message,
            "No installed language pair found for target: zh-Hans"
        );
    }

    #[test]
    fn malformed_translation_error_falls_back_to_generic_code() {
        let failure = decode_translate_result("__error__:unexpected framework failure".to_string())
            .unwrap_err();

        assert_eq!(failure.code, "ERR_TRANSLATE_FAILED");
        assert_eq!(failure.message, "unexpected framework failure");
    }
}
