#![deny(clippy::all)]

use napi::bindgen_prelude::*;
use napi_derive::napi;
use std::ffi::{CStr, CString};

// ── FFI declarations ──────────────────────────────────────────────────────────

#[allow(improper_ctypes)]
extern "C" {
    fn translate_text_ffi(text: *const i8, target_lang: *const i8) -> *mut i8;
    fn free_translate_result(ptr: *mut i8);

    fn recognize_speech_ffi(file_path: *const i8, lang: *const i8) -> *mut i8;
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
}

impl Task for RecognizeSpeechTask {
    type Output = String;
    type JsValue = String;

    fn compute(&mut self) -> Result<Self::Output> {
        let c_path = cstring(&self.file_path)?;
        let c_lang = cstring(&self.lang)?;

        let ptr = unsafe { recognize_speech_ffi(c_path.as_ptr(), c_lang.as_ptr()) };
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

/// Recognize speech from an audio file using macOS Speech framework.
/// Requires prior authorization via requestSpeechPermission().
/// filePath: absolute path to audio file (WAV, M4A, FLAC, MP3, etc.)
/// lang:     BCP-47 locale, e.g. "en-US", "zh-CN"
#[napi]
pub fn recognize_speech(file_path: String, lang: String) -> AsyncTask<RecognizeSpeechTask> {
    AsyncTask::new(RecognizeSpeechTask { file_path, lang })
}
