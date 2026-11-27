const path = require('path');
const { getDefaultConfig, mergeConfig } = require('@react-native/metro-config');

// @tugboat/react-native is `file:..`: Metro must watch it, and resolve react and
// react-native from this app only.
const sdk = path.resolve(__dirname, '..');

const config = {
  watchFolders: [sdk],
  resolver: {
    nodeModulesPaths: [path.resolve(__dirname, 'node_modules')],
    extraNodeModules: {
      react: path.resolve(__dirname, 'node_modules/react'),
      'react-native': path.resolve(__dirname, 'node_modules/react-native'),
    },
  },
};

module.exports = mergeConfig(getDefaultConfig(__dirname), config);
