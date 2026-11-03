const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');

const execute = promisify(execFile);

test('real anonymous probes return 302 without redirects, cookies, credentials or body buffering', { timeout: 30000 }, async (t) => {
  const requests = [];
  const server = http.createServer((req, res) => {
    requests.push({ path: req.url, authorization: req.headers.authorization, cookie: req.headers.cookie });
    if (req.url === '/redirect') {
      res.writeHead(302, { Location: '/must-not-follow', 'Set-Cookie': 'fixture=must-not-return; HttpOnly' }).end();
    } else if (req.url === '/denied') {
      res.writeHead(401, { 'Content-Type': 'text/plain' });
      res.flushHeaders();
    } else {
      res.writeHead(200).end('Unexpected redirect follow');
    }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  });
  const { stdout } = await execute('pwsh', [
    '-NoLogo', '-NoProfile', '-Command',
    '. $env:FIXTURE_HOOK_PATH -LoadOnly; @(Invoke-AnonymousProbe "$env:FIXTURE_ORIGIN/redirect"; Invoke-AnonymousProbe "$env:FIXTURE_ORIGIN/denied") | ConvertTo-Json -Compress',
  ], {
    env: {
      PATH: process.env.PATH,
      ...(process.env.SYSTEMROOT ? { SYSTEMROOT: process.env.SYSTEMROOT } : {}),
      FIXTURE_HOOK_PATH: path.resolve(__dirname, '../../scripts/azd.ps1'),
      FIXTURE_ORIGIN: `http://127.0.0.1:${server.address().port}`,
    },
    timeout: 20000,
    maxBuffer: 65536,
  });
  assert.deepEqual(JSON.parse(stdout.trim()), [302, 401]);
  assert.deepEqual(requests.map((req) => req.path), ['/redirect', '/denied']);
  assert.ok(requests.every((req) => req.authorization === undefined && req.cookie === undefined));
});
