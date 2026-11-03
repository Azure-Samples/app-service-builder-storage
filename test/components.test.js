const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync, readdirSync } = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const readPackage = directory => JSON.parse(readFileSync(path.join(root, directory, 'package.json'), 'utf8'));

test('frontend and API dependencies have independent framework detection roots', () => {
  const orchestration = readPackage('.');
  const client = readPackage('client');
  const server = readPackage('server');
  assert.equal(orchestration.dependencies, undefined);
  assert.equal(orchestration.devDependencies.vite, undefined);
  assert.ok(client.devDependencies.vite);
  assert.ok(server.dependencies['@azure/storage-blob']);
  assert.ok(server.dependencies['@azure/identity']);
  assert.equal(server.dependencies.vite, undefined);
  assert.equal(server.devDependencies, undefined);
  assert.ok(readdirSync(path.join(root, 'client')).includes('vite.config.mjs'));
  assert.ok(!readdirSync(path.join(root, 'server')).some(name => name.startsWith('vite.config.')));
  for (const component of ['client', 'server']) {
    const lock = JSON.parse(readFileSync(path.join(root, component, 'package-lock.json'), 'utf8'));
    assert.equal(lock.packages[''].name, readPackage(component).name);
  }
});

test('manifest keeps the public API prefix and web health within its mount', () => {
  const manifest = readFileSync(path.join(root, 'builder.yaml'), 'utf8');
  const [frontend, api] = manifest.split('  - name: ').slice(1);
  assert.match(frontend, /role: static/);
  assert.match(frontend, /rootDirectory: client/);
  assert.match(frontend, /output: dist/);
  assert.ok(!/\n\s+run:/.test(frontend));
  assert.match(api, /role: web/);
  assert.match(api, /rootDirectory: server/);
  assert.match(api, /path: \/api\n/);
  assert.match(api, /start: node index\.js/);
  assert.match(api, /healthCheckPath: \/api\/health/);
});
