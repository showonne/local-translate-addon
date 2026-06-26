import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);

const arch = process.arch === 'arm64' ? 'arm64' : 'x64';
const addon = require(join(__dirname, '..', `macos-translate.darwin-${arch}.node`));

test('translateText returns a string', async () => {
  const result = await addon.translateText('Hello world', 'zh-CN');
  assert.equal(typeof result, 'string');
  assert.ok(result.length > 0, 'result should be non-empty');
  console.log(`  Translation result: "${result}"`);
});

test('translateText rejects on unsupported language', async () => {
  await assert.rejects(
    () => addon.translateText('Hello', 'xx-INVALID'),
    (err) => {
      assert.ok(err instanceof Error);
      return true;
    }
  );
});
