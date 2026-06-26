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

const __dirname = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);

const arch = process.arch === 'arm64' ? 'arm64' : 'x64';
const addonPath = join(__dirname, '..', `macos-translate.darwin-${arch}.node`);

test('addon loads without error', () => {
  const addon = require(addonPath);
  assert.ok(addon, 'addon should be truthy');
});

test('translateText is exported as a function', () => {
  const addon = require(addonPath);
  assert.equal(typeof addon.translateText, 'function', 'translateText should be a function');
});

test('translateText returns a Promise', () => {
  // We kick off the call but do NOT await it — just verify it returns a Promise.
  // Awaiting would hang because Translation.framework needs Electron's RunLoop.
  const addon = require(addonPath);
  const result = addon.translateText('Hello', 'zh-CN');
  assert.ok(result instanceof Promise, 'translateText should return a Promise');
  // Cancel the pending promise to avoid hanging the test runner.
  result.catch(() => {});
});
