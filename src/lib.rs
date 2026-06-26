#![deny(clippy::all)]

use napi::bindgen_prelude::*;
use napi_derive::napi;
use std::ffi::{CStr, CString};

#[allow(improper_ctypes)]
extern "C" {
    fn translate_text_ffi(text: *const i8, target_lang: *const i8) -> *mut i8;
    fn free_translate_result(ptr: *mut i8);
}

struct TranslateTask {
    text: String,
    target_lang: String,
}

impl Task for TranslateTask {
    type Output = String;
    type JsValue = String;

    fn compute(&mut self) -> Result<Self::Output> {
        let c_text = CString::new(self.text.as_str())
            .map_err(|e| Error::from_reason(e.to_string()))?;
        let c_lang = CString::new(self.target_lang.as_str())
            .map_err(|e| Error::from_reason(e.to_string()))?;

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
