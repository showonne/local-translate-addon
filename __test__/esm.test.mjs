import { test } from 'node:test';
import assert from 'node:assert/strict';
import { TranslateErrorCode, translateText, isTranslateTextSupport } from '../index.js';

test('package supports static named imports from ESM', () => {
  assert.equal(typeof TranslateErrorCode, 'object');
  assert.equal(typeof translateText, 'function');
  assert.equal(typeof isTranslateTextSupport, 'function');
});
