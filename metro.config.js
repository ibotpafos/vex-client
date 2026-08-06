const { getDefaultConfig } = require("expo/metro-config");
const exclusionList = require("metro-config/private/defaults/exclusionList").default;

/** @type {import('expo/metro-config').MetroConfig} */
const config = getDefaultConfig(__dirname);

config.transformer.inlineRequires = true;

config.resolver.blockList = exclusionList([
  /\/\.env\..*\.local$/,
  /\/.*\.env\.local$/,
  /\/\.env\.signing\.local$/,
  /\/android\/\.gradle\/.*/,
  /\/android\/app\/build\/.*/,
  /\/artifacts\/.*/,
]);

module.exports = config;
