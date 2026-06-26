'use strict';

const { existsSync } = require('fs');
const { join } = require('path');

const arch = process.arch === 'arm64' ? 'arm64' : 'x64';
const addonPath = join(__dirname, `macos-translate.darwin-${arch}.node`);

if (!existsSync(addonPath)) {
  throw new Error(`macos-translate: prebuilt addon not found at ${addonPath}`);
}

module.exports = require(addonPath);
