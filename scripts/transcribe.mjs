import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const addon = require('../index.js');

function usage() {
  console.error(
    'usage: node scripts/transcribe.mjs <audio-file> [lang=zh-CN] [--download] [--timeout=<ms>]'
  );
  process.exit(2);
}

const [, , filePath, ...rest] = process.argv;
if (!filePath) {
  usage();
}
const lang = rest.find(arg => !arg.startsWith('--')) ?? 'zh-CN';
const download = rest.includes('--download');
const timeoutMs =
  Number(rest.find(arg => arg.startsWith('--timeout='))?.slice('--timeout='.length)) || undefined;

console.log(`supported: ${addon.isTranscribeAudioSupport()}`);
const status = await addon.getTranscribeAudioModelStatus(lang);
console.log(`model status(${lang}): ${status}`);

if (status === 'downloadRequired') {
  if (!download) {
    console.log('pass --download to install the model first');
    process.exit(1);
  }
  const startedAt = performance.now();
  await addon.downloadTranscribeAudioModel(lang);
  console.log(`downloaded in ${Math.round(performance.now() - startedAt)}ms`);
}

const audio = new Uint8Array(await readFile(filePath));
const startedAt = performance.now();
try {
  const text = await addon.transcribeAudio(audio, lang, { timeoutMs });
  console.log(`[${Math.round(performance.now() - startedAt)}ms]\n${text}`);
} catch (error) {
  console.log(
    `[${Math.round(performance.now() - startedAt)}ms] FAILED: ${error.code} ${error.message}`
  );
  process.exit(1);
}
