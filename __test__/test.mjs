/**
 * Integration tests for @difft/macos-translate.
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
    UNSUPPORT_OS_VERSION: 'ERR_TRANSLATE_UNSUPPORTED_OS_VERSION',
    LANGUAGE_PAIR_NOT_INSTALLED: 'ERR_TRANSLATE_LANGUAGE_PAIR_NOT_INSTALLED',
    FAILED: 'ERR_TRANSLATE_FAILED',
  });
});

test('speech recognition exports offline controls', () => {
  const addon = require(addonPath);
  assert.equal(typeof addon.getSpeechRecognitionCapabilities, 'function');
  assert.equal(typeof addon.recognizeSpeech, 'function');
  assert.equal(typeof addon.recognizeSpeechWithOptions, 'undefined');
});

test('isLocalTranslateAvailable matches the macOS 26 boundary', () => {
  const addon = require(addonPath);
  const majorVersion = Number(
    execFileSync('/usr/bin/sw_vers', ['-productVersion'], { encoding: 'utf8' })
      .trim()
      .split('.')[0]
  );

  assert.equal(typeof addon.isLocalTranslateAvailable, 'function');
  assert.equal(addon.isLocalTranslateAvailable(), majorVersion >= 26);
});
