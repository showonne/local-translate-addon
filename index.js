const { createLocalTranslate } = require('./entry');

const {
  TranslateErrorCode,
  TranscribeErrorCode,
  translateText,
  isTranslateTextSupport,
  isTranscribeAudioSupport,
  getTranscribeAudioModelStatus,
  downloadTranscribeAudioModel,
  releaseTranscribeAudioModel,
  transcribeAudio,
} = createLocalTranslate(() => require('./binding'));

module.exports = {
  TranslateErrorCode,
  TranscribeErrorCode,
  translateText,
  isTranslateTextSupport,
  isTranscribeAudioSupport,
  getTranscribeAudioModelStatus,
  downloadTranscribeAudioModel,
  releaseTranscribeAudioModel,
  transcribeAudio,
};
