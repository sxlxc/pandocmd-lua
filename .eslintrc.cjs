module.exports = {
  env: {
    browser: true,
    es2021: true,
    node: true,
  },
  extends: ['google'],
  ignorePatterns: ['assets/js/vendor/**'],
  parserOptions: {
    sourceType: 'script',
  },
  rules: {
    'max-len': ['error', {code: 100, ignoreUrls: true}],
    'require-jsdoc': 'off',
    'valid-jsdoc': 'off',
  },
};
