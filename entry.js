const TranslateErrorCode = Object.freeze({
  UNSUPPORTED_PLATFORM: 'ERR_TRANSLATE_UNSUPPORTED_PLATFORM',
  UNSUPPORT_OS_VERSION: 'ERR_TRANSLATE_UNSUPPORTED_OS_VERSION',
  LANGUAGE_PAIR_NOT_INSTALLED: 'ERR_TRANSLATE_LANGUAGE_PAIR_NOT_INSTALLED',
  LANGUAGE_PAIR_NOT_READY: 'ERR_TRANSLATE_LANGUAGE_PAIR_NOT_READY',
  FAILED: 'ERR_TRANSLATE_FAILED',
});

const TranscribeErrorCode = Object.freeze({
  UNSUPPORTED_PLATFORM: 'ERR_TRANSCRIBE_UNSUPPORTED_PLATFORM',
  UNSUPPORTED_OS_VERSION: 'ERR_TRANSCRIBE_UNSUPPORTED_OS_VERSION',
  UNSUPPORTED_LANGUAGE: 'ERR_TRANSCRIBE_UNSUPPORTED_LANGUAGE',
  MODEL_NOT_INSTALLED: 'ERR_TRANSCRIBE_MODEL_NOT_INSTALLED',
  MODEL_DOWNLOAD_FAILED: 'ERR_TRANSCRIBE_MODEL_DOWNLOAD_FAILED',
  AUDIO_DECODE_FAILED: 'ERR_TRANSCRIBE_AUDIO_DECODE_FAILED',
  AUDIO_TOO_LONG: 'ERR_TRANSCRIBE_AUDIO_TOO_LONG',
  TIMEOUT: 'ERR_TRANSCRIBE_TIMEOUT',
  FAILED: 'ERR_TRANSCRIBE_FAILED',
});

function unsupportedPlatformError(message, code, cause) {
  const error = new Error(message);
  error.code = code;
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
      TranscribeErrorCode,
      translateText: binding.translateText,
      isTranslateTextSupport: binding.isTranslateTextSupport,
      isTranscribeAudioSupport: binding.isTranscribeAudioSupport,
      getTranscribeAudioModelStatus: binding.getTranscribeAudioModelStatus,
      downloadTranscribeAudioModel: binding.downloadTranscribeAudioModel,
      transcribeAudio: binding.transcribeAudio,
    };
  }

  const rejectTranslate = async () => {
    throw unsupportedPlatformError(
      'Local translate is not available on this platform',
      TranslateErrorCode.UNSUPPORTED_PLATFORM,
      loadError
    );
  };
  const rejectTranscribe = async () => {
    throw unsupportedPlatformError(
      'Local speech transcription is not available on this platform',
      TranscribeErrorCode.UNSUPPORTED_PLATFORM,
      loadError
    );
  };

  return {
    TranslateErrorCode,
    TranscribeErrorCode,
    translateText: rejectTranslate,
    isTranslateTextSupport: () => false,
    isTranscribeAudioSupport: () => false,
    getTranscribeAudioModelStatus: async () => 'unsupported',
    downloadTranscribeAudioModel: rejectTranscribe,
    transcribeAudio: rejectTranscribe,
  };
}

module.exports = { createLocalTranslate, TranslateErrorCode, TranscribeErrorCode };
