import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const addon = require('../index.js');

const TIMEOUT_MS = 60_000;

function usage() {
  console.error(
    'usage: node scripts/compare-speech.mjs <audio-file> [lang=en-US] [--on-device] [--only=file|buffer]'
  );
  process.exit(2);
}

const [, , filePath, ...rest] = process.argv;
if (!filePath) {
  usage();
}
const lang = rest.find(arg => !arg.startsWith('--')) ?? 'en-US';
const onDeviceOnly = rest.includes('--on-device');
const only = rest.find(arg => arg.startsWith('--only='))?.slice('--only='.length);

function withTimeout(promise, label) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(
      () => reject(new Error(`${label} timed out after ${TIMEOUT_MS}ms`)),
      TIMEOUT_MS
    );
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

async function timed(label, run) {
  const startedAt = performance.now();
  try {
    const text = await withTimeout(run(), label);
    const elapsedMs = Math.round(performance.now() - startedAt);
    console.log(`[${label}] ${elapsedMs}ms\n${text}\n`);
    return { label, elapsedMs, text };
  } catch (error) {
    const elapsedMs = Math.round(performance.now() - startedAt);
    console.log(`[${label}] ${elapsedMs}ms FAILED: ${error.message}\n`);
    return { label, elapsedMs, error };
  }
}

const status = await addon.requestSpeechPermission();
console.log(`permission: ${status}`);
console.log(`capabilities(${lang}):`, addon.getSpeechRecognitionCapabilities(lang));
console.log(`onDeviceOnly: ${onDeviceOnly}\n`);

const options = { onDeviceOnly };
const results = [];
if (only !== 'buffer') {
  results.push(
    await timed('file', () => addon.recognizeSpeech(filePath, lang, options))
  );
}
if (only !== 'file') {
  const audio = new Uint8Array(await readFile(filePath));
  results.push(
    await timed('buffer', () =>
      addon.recognizeSpeechBuffer(audio, lang, options)
    )
  );
}

const [a, b] = results;
if (a && b && a.text !== undefined && b.text !== undefined) {
  console.log(a.text === b.text ? 'texts match' : 'texts differ');
}
