/**
 * Integration tests for local-translate-addon.
 *
 * NOTE: Translation.framework requires the main thread's RunLoop to be active
 * (the "Electron condition"). Plain `node` does not pump the main RunLoop, so
 * the actual translation call would hang. These tests only verify that the
 * native addon loads correctly and exports the expected API.
 * Real end-to-end testing happens in TempTalk-Desktop (Electron context).
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';
import { execFileSync } from 'node:child_process';

const __dirname = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);

const addonPath = join(__dirname, '..');
const { createLocalTranslate } = require('../entry.js');

test('addon loads without error', () => {
  const addon = require(addonPath);
  assert.ok(addon, 'addon should be truthy');
});

test('translateText is exported as a function', () => {
  const addon = require(addonPath);
  assert.equal(typeof addon.translateText, 'function', 'translateText should be a function');
});

test('TranslateErrorCode exports stable error codes', () => {
  const addon = require(addonPath);
  assert.deepEqual(addon.TranslateErrorCode, {
    UNSUPPORTED_PLATFORM: 'ERR_TRANSLATE_UNSUPPORTED_PLATFORM',
    UNSUPPORT_OS_VERSION: 'ERR_TRANSLATE_UNSUPPORTED_OS_VERSION',
    LANGUAGE_PAIR_NOT_INSTALLED: 'ERR_TRANSLATE_LANGUAGE_PAIR_NOT_INSTALLED',
    FAILED: 'ERR_TRANSLATE_FAILED',
  });
});

test('speech recognition exports offline controls', () => {
  const addon = require(addonPath);
  assert.equal(typeof addon.getSpeechRecognitionCapabilities, 'function');
  assert.equal(typeof addon.recognizeSpeech, 'function');
  assert.equal(typeof addon.recognizeSpeechBuffer, 'function');
  assert.equal(typeof addon.recognizeSpeechWithOptions, 'undefined');
});

test('isTranslateTextSupport matches the macOS 26 boundary', () => {
  const addon = require(addonPath);
  const majorVersion = Number(
    execFileSync('/usr/bin/sw_vers', ['-productVersion'], { encoding: 'utf8' })
      .trim()
      .split('.')[0]
  );

  assert.equal(typeof addon.isTranslateTextSupport, 'function');
  assert.equal(addon.isTranslateTextSupport(), majorVersion >= 26);
});

test('isRecognizeSpeechSupport mirrors speech capabilities', () => {
  const addon = require(addonPath);
  const caps = addon.getSpeechRecognitionCapabilities('en-US');

  assert.equal(addon.isRecognizeSpeechSupport('en-US'), caps.isAvailable);
  assert.equal(
    addon.isRecognizeSpeechSupport('en-US', { onDeviceOnly: true }),
    caps.isAvailable && caps.supportsOnDeviceRecognition
  );
  assert.equal(addon.isRecognizeSpeechSupport('xx-INVALID'), false);
});

test('entry error codes cover every native error code', () => {
  const binding = require('../binding.js');
  const addon = require(addonPath);
  for (const [key, value] of Object.entries(binding.TranslateErrorCode)) {
    assert.equal(addon.TranslateErrorCode[key], value);
  }
});

test('package entry exposes exactly the public API', () => {
  const addon = require(addonPath);
  assert.deepEqual(Object.keys(addon).sort(), [
    'TranslateErrorCode',
    'getSpeechRecognitionCapabilities',
    'isRecognizeSpeechSupport',
    'isTranslateTextSupport',
    'recognizeSpeech',
    'recognizeSpeechBuffer',
    'requestSpeechPermission',
    'translateText',
  ]);
});

test('entry falls back when the native binding cannot load', async () => {
  const api = createLocalTranslate(() => {
    throw new Error('dlopen failed');
  });

  assert.equal(api.isTranslateTextSupport(), false);
  assert.equal(api.isRecognizeSpeechSupport('en-US', { onDeviceOnly: true }), false);
  assert.deepEqual(api.getSpeechRecognitionCapabilities('en-US'), {
    isAvailable: false,
    supportsOnDeviceRecognition: false,
    isAuthorized: false,
  });

  for (const pending of [
    api.translateText('hello', 'zh-Hans'),
    api.requestSpeechPermission(),
    api.recognizeSpeech('/tmp/a.m4a', 'en-US'),
  ]) {
    await assert.rejects(pending, error => {
      assert.equal(error.code, 'ERR_TRANSLATE_UNSUPPORTED_PLATFORM');
      assert.equal(error.cause.message, 'dlopen failed');
      return true;
    });
  }
});

test('entry falls back for recognizeSpeechBuffer', async () => {
  const api = createLocalTranslate(() => {
    throw new Error('nope');
  });

  await assert.rejects(api.recognizeSpeechBuffer(new Uint8Array(), 'en-US'), error => {
    assert.equal(error.code, 'ERR_TRANSLATE_UNSUPPORTED_PLATFORM');
    return true;
  });
});
