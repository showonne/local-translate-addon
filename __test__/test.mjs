/**
 * Integration tests for local-translate-addon.
 *
 * NOTE: Translation.framework requires the main thread's RunLoop to be active
 * (the "Electron condition"). Plain `node` does not pump the main RunLoop, so
 * the actual translation call would hang. These tests only verify that the
 * native addon loads correctly and exports the expected API.
 * Real end-to-end testing happens in TempTalk-Desktop (Electron context).
 *
 * Speech transcription does not need the main RunLoop, so its tests run end to
 * end here wherever the system supports it, and skip elsewhere.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';

const __dirname = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);

const addonPath = join(__dirname, '..');
const { createLocalTranslate } = require('../entry.js');

const macosMajorVersion = Number(
  execFileSync('/usr/bin/sw_vers', ['-productVersion'], { encoding: 'utf8' })
    .trim()
    .split('.')[0]
);

function silentWav(seconds) {
  const sampleRate = 16000;
  const dataSize = seconds * sampleRate * 2;
  const wav = Buffer.alloc(44 + dataSize);
  wav.write('RIFF', 0);
  wav.writeUInt32LE(36 + dataSize, 4);
  wav.write('WAVE', 8);
  wav.write('fmt ', 12);
  wav.writeUInt32LE(16, 16);
  wav.writeUInt16LE(1, 20);
  wav.writeUInt16LE(1, 22);
  wav.writeUInt32LE(sampleRate, 24);
  wav.writeUInt32LE(sampleRate * 2, 28);
  wav.writeUInt16LE(2, 32);
  wav.writeUInt16LE(16, 34);
  wav.write('data', 36);
  wav.writeUInt32LE(dataSize, 40);
  return new Uint8Array(wav);
}

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
    LANGUAGE_PAIR_NOT_READY: 'ERR_TRANSLATE_LANGUAGE_PAIR_NOT_READY',
  LANGUAGE_PAIR_NOT_READY: 'ERR_TRANSLATE_LANGUAGE_PAIR_NOT_READY',
    FAILED: 'ERR_TRANSLATE_FAILED',
  });
});

test('speech transcription exports one engine-agnostic API', () => {
  const addon = require(addonPath);
  assert.equal(typeof addon.isTranscribeAudioSupport, 'function');
  assert.equal(typeof addon.getTranscribeAudioModelStatus, 'function');
  assert.equal(typeof addon.downloadTranscribeAudioModel, 'function');
  assert.equal(typeof addon.transcribeAudio, 'function');
  for (const removed of [
    'requestSpeechPermission',
    'recognizeSpeech',
    'recognizeSpeechBuffer',
    'getSpeechRecognitionCapabilities',
    'isRecognizeSpeechSupport',
  ]) {
    assert.equal(addon[removed], undefined, removed);
  }
});

test('isTranslateTextSupport matches the macOS 26 boundary', () => {
  const addon = require(addonPath);

  assert.equal(typeof addon.isTranslateTextSupport, 'function');
  assert.equal(addon.isTranslateTextSupport(), macosMajorVersion >= 26);
});

test('isTranscribeAudioSupport is false before macOS 26', () => {
  const addon = require(addonPath);
  const supported = addon.isTranscribeAudioSupport();

  assert.equal(typeof supported, 'boolean');
  if (macosMajorVersion < 26) {
    assert.equal(supported, false);
  }
});

test('getTranscribeAudioModelStatus reports one of three states without downloading', async () => {
  const addon = require(addonPath);
  const states = ['ready', 'downloadRequired', 'unsupported'];

  assert.ok(states.includes(await addon.getTranscribeAudioModelStatus('zh-CN')));
  assert.ok(states.includes(await addon.getTranscribeAudioModelStatus('en-US')));
  assert.equal(await addon.getTranscribeAudioModelStatus('xx-INVALID'), 'unsupported');
  if (!addon.isTranscribeAudioSupport()) {
    assert.equal(await addon.getTranscribeAudioModelStatus('zh-CN'), 'unsupported');
  }
});

test('transcribeAudio rejects with a transcribe error code', async t => {
  const addon = require(addonPath);
  if (!addon.isTranscribeAudioSupport()) {
    await assert.rejects(addon.transcribeAudio(silentWav(1), 'zh-CN'), error => {
      assert.equal(error.code, 'ERR_TRANSCRIBE_UNSUPPORTED_OS_VERSION');
      return true;
    });
    t.skip('speech transcription is not available here');
    return;
  }

  await assert.rejects(addon.transcribeAudio(new Uint8Array([1, 2, 3, 4]), 'zh-CN'), error => {
    assert.equal(error.code, 'ERR_TRANSCRIBE_AUDIO_DECODE_FAILED');
    return true;
  });
  await assert.rejects(addon.transcribeAudio(silentWav(1), 'xx-INVALID'), error => {
    assert.equal(error.code, 'ERR_TRANSCRIBE_UNSUPPORTED_LANGUAGE');
    return true;
  });
});

test('transcribeAudio returns empty text for silence', async t => {
  const addon = require(addonPath);
  if (!addon.isTranscribeAudioSupport()) {
    t.skip('speech transcription is not available here');
    return;
  }

  assert.equal(await addon.transcribeAudio(silentWav(3), 'zh-CN'), '');
});

test('transcribeAudio transcribes synthesized speech', async t => {
  const addon = require(addonPath);
  if (
    !addon.isTranscribeAudioSupport() ||
    (await addon.getTranscribeAudioModelStatus('en-US')) !== 'ready'
  ) {
    t.skip('the en-US model is not installed here');
    return;
  }

  const dir = mkdtempSync(join(tmpdir(), 'local-transcribe-'));
  try {
    const file = join(dir, 'fox.m4a');
    execFileSync('/usr/bin/say', [
      '-o',
      file,
      '--data-format=aac',
      'The quick brown fox jumps over the lazy dog.',
    ]);
    const text = await addon.transcribeAudio(new Uint8Array(readFileSync(file)), 'en-US');
    assert.match(text.toLowerCase(), /quick brown fox/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('entry error codes cover every native error code', () => {
  const binding = require('../binding.js');
  const addon = require(addonPath);
  for (const [key, value] of Object.entries(binding.TranslateErrorCode)) {
    assert.equal(addon.TranslateErrorCode[key], value);
  }
  for (const [key, value] of Object.entries(binding.TranscribeErrorCode)) {
    assert.equal(addon.TranscribeErrorCode[key], value);
  }
});

test('package entry exposes exactly the public API', () => {
  const addon = require(addonPath);
  assert.deepEqual(Object.keys(addon).sort(), [
    'TranscribeErrorCode',
    'TranslateErrorCode',
    'downloadTranscribeAudioModel',
    'getTranscribeAudioModelStatus',
    'isTranscribeAudioSupport',
    'isTranslateTextSupport',
    'transcribeAudio',
    'translateText',
  ]);
});

test('entry falls back when the native binding cannot load', async () => {
  const api = createLocalTranslate(() => {
    throw new Error('dlopen failed');
  });

  assert.equal(api.isTranslateTextSupport(), false);
  assert.equal(api.isTranscribeAudioSupport(), false);
  assert.equal(await api.getTranscribeAudioModelStatus('zh-CN'), 'unsupported');

  await assert.rejects(api.translateText('hello', 'zh-Hans'), error => {
    assert.equal(error.code, 'ERR_TRANSLATE_UNSUPPORTED_PLATFORM');
    assert.equal(error.cause.message, 'dlopen failed');
    return true;
  });
  for (const pending of [
    api.downloadTranscribeAudioModel('zh-CN'),
    api.transcribeAudio(new Uint8Array(), 'zh-CN'),
  ]) {
    await assert.rejects(pending, error => {
      assert.equal(error.code, 'ERR_TRANSCRIBE_UNSUPPORTED_PLATFORM');
      assert.equal(error.cause.message, 'dlopen failed');
      return true;
    });
  }
});
