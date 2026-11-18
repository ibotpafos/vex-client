const { getDefaultConfig } = require("expo/metro-config");
const exclusionList = require("metro-config/private/defaults/exclusionList").default;

/** @type {import('expo/metro-config').MetroConfig} */
const config = getDefaultConfig(__dirname);

// Modern Metro optimizations: parallel transformation on all CPU cores,
// aggressive inline requires for faster app startup, persistent file-map cache.
config.transformer.inlineRequires = true;
config.transformer.maxWorkers = Math.max(1, Math.floor(require('os').cpus().length * 0.8));
config.resolver.useWatchman = false;
config.fileMapCacheDirectory = __dirname + "/.metro-file-map-cache";

// Production minification: tighter dead-code elimination and smaller bundle.
if (process.env.NODE_ENV === 'production') {
  config.transformer.minifierConfig = {
    mangle: { safari10: true },
    compress: {
      drop_console: true,
      drop_debugger: true,
      pure_funcs: ['console.log', 'console.info', 'console.debug', 'console.warn'],
      passes: 2,
    },
    output: { beautify: false },
  };
}

config.resolver.blockList = exclusionList([
  /\/\.env\..*\.local$/,
  /\/.*\.env\.local$/,
  /\/\.env\.signing\.local$/,
  /\/android\/\.gradle\/.*/,
  /\/android\/app\/build\/.*/,
  /\/artifacts\/.*/,
]);

module.exports = config;
