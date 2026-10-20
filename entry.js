const TranslateErrorCode = Object.freeze({
  UNSUPPORTED_PLATFORM: 'ERR_TRANSLATE_UNSUPPORTED_PLATFORM',
  UNSUPPORT_OS_VERSION: 'ERR_TRANSLATE_UNSUPPORTED_OS_VERSION',
  LANGUAGE_PAIR_NOT_INSTALLED: 'ERR_TRANSLATE_LANGUAGE_PAIR_NOT_INSTALLED',
  FAILED: 'ERR_TRANSLATE_FAILED',
});

function unsupportedPlatformError(cause) {
  const error = new Error('Local translate is not available on this platform');
  error.code = TranslateErrorCode.UNSUPPORTED_PLATFORM;
  if (cause !== undefined) {
    error.cause = cause;
  }
  return error;
}

function createLocalTranslate(loadBinding) {
  let binding = null;
  let loadError;
  try {
    binding = loadBinding();
  } catch (error) {
    loadError = error;
  }

  if (binding) {
    return {
      TranslateErrorCode,
      translateText: binding.translateText,
      isTranslateTextSupport: binding.isTranslateTextSupport,
      requestSpeechPermission: binding.requestSpeechPermission,
      recognizeSpeech: binding.recognizeSpeech,
      recognizeSpeechBuffer: binding.recognizeSpeechBuffer,
      getSpeechRecognitionCapabilities: binding.getSpeechRecognitionCapabilities,
      isRecognizeSpeechSupport: binding.isRecognizeSpeechSupport,
    };
  }

  const reject = async () => {
    throw unsupportedPlatformError(loadError);
  };

  return {
    TranslateErrorCode,
    translateText: reject,
    isTranslateTextSupport: () => false,
    requestSpeechPermission: reject,
    recognizeSpeech: reject,
    recognizeSpeechBuffer: reject,
    getSpeechRecognitionCapabilities: () => ({
      isAvailable: false,
      supportsOnDeviceRecognition: false,
      isAuthorized: false,
    }),
    isRecognizeSpeechSupport: () => false,
  };
}

module.exports = { createLocalTranslate, TranslateErrorCode };
