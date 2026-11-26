module.exports = {
  preset: 'react-native',
  setupFiles: ['./jest.setup.js'],
  // React Navigation 7 ships ESM, so let Babel transform it alongside React Native.
  transformIgnorePatterns: [
    'node_modules/(?!((jest-)?react-native|@react-native(-community)?|@react-navigation)/)',
  ],
  moduleNameMapper: {
    '\\.(png|jpg|jpeg|gif|webp|ttf)$': '<rootDir>/__mocks__/fileMock.js',
    '^\\.\\./\\.\\./\\.\\./config\\.json$': '<rootDir>/config.test.json',
  },
};
