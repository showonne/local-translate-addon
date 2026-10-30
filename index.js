const { createLocalTranslate } = require('./entry');

const {
  TranslateErrorCode,
  TranscribeErrorCode,
  translateText,
  isTranslateTextSupport,
  isTranscribeAudioSupport,
  getTranscribeAudioModelStatus,
  downloadTranscribeAudioModel,
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
  transcribeAudio,
};
