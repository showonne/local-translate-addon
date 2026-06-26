'use strict';

const { existsSync } = require('fs');
const { join } = require('path');

if (process.platform !== 'darwin') {
  throw new Error(
    `macos-translate: only supported on macOS (platform: ${process.platform})`
  );
}

if (process.arch !== 'arm64' && process.arch !== 'x64') {
  throw new Error(
    `macos-translate: unsupported architecture: ${process.arch}`
  );
}

const arch = process.arch === 'arm64' ? 'arm64' : 'x64';
const addonPath = join(__dirname, `macos-translate.darwin-${arch}.node`);

if (!existsSync(addonPath)) {
  throw new Error(`macos-translate: prebuilt addon not found at ${addonPath}`);
}

module.exports = require(addonPath);
