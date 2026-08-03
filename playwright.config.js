const {defineConfig, devices} = require('@playwright/test');

module.exports = defineConfig({
  testDir: './tests/browser',
  testIgnore: process.env.PANDOCMD_BENCHMARK ? [] : ['**/benchmark.spec.js'],
  timeout: 30000,
  expect: {timeout: 5000},
  fullyParallel: false,
  reporter: 'line',
  use: {
    baseURL: 'http://127.0.0.1:4173',
    viewport: {width: 1000, height: 800},
  },
  projects: [
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        ...(process.env.PANDOCMD_SYSTEM_CHROME ? {channel: 'chrome'} : {}),
      },
    },
    {name: 'webkit', use: {...devices['Desktop Safari']}},
  ],
  webServer: {
    command: 'fixture_hash="$(bin/pandocmd-preview --hash-only tests/browser/fixture.md)" && ' +
      'mkdir -p assets/preview && ' +
      'PANDOCMD_ASSETS_DIR="$PWD/assets" pandoc tests/browser/fixture.md ' +
      '--resource-path "tests/browser:." -f lua/reader.lua -L lua/filter.lua ' +
      '-t lua/writer.lua -o "assets/preview/${fixture_hash}.html" && ' +
      'python3 -m http.server 4173 --directory assets',
    port: 4173,
    reuseExistingServer: true,
  },
});
