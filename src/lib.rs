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

pub struct TranslateTask {
    text: String,
    target_lang: String,
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

#[napi]
pub fn translate_text(text: String, target_lang: String) -> AsyncTask<TranslateTask> {
    AsyncTask::new(TranslateTask { text, target_lang })
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
