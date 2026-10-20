const { createLocalTranslate } = require('./entry');

const {
  TranslateErrorCode,
  translateText,
  isTranslateTextSupport,
  requestSpeechPermission,
  recognizeSpeech,
  getSpeechRecognitionCapabilities,
  isRecognizeSpeechSupport,
} = createLocalTranslate(() => require('./binding'));

module.exports = {
  TranslateErrorCode,
  translateText,
  isTranslateTextSupport,
  requestSpeechPermission,
  recognizeSpeech,
  getSpeechRecognitionCapabilities,
  isRecognizeSpeechSupport,
};
