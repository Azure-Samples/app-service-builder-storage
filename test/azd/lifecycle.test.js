const test = require('node:test');
const assert = require('node:assert/strict');
const { mkdtemp, mkdir, writeFile, readFile, rm } = require('node:fs/promises');
const { tmpdir } = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');

const execute = promisify(execFile);

test('real azd executes an explicit project hook without services or network', { timeout: 90000 }, async (t) => {
  const root = await mkdtemp(path.join(tmpdir(), 'shopstream-azd-'));
  const requests = [];
  const proxy = http.createServer((req, res) => {
    requests.push(new URL(req.url, 'http://unknown.invalid').hostname);
    res.writeHead(502).end();
  });
  proxy.on('connect', (req, socket) => {
    requests.push(req.url.split(':')[0]);
    socket.end('HTTP/1.1 502 Offline fixture\r\n\r\n');
  });
  await new Promise((resolve) => proxy.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    await new Promise((resolve) => proxy.close(resolve));
    await rm(root, { recursive: true, force: true });
  });
  const project = path.join(root, 'project');
  await mkdir(path.join(project, '.azure', 'offline'), { recursive: true });
  await mkdir(path.join(root, 'home'));
  await writeFile(path.join(project, '.azure', 'config.json'), JSON.stringify({ defaultEnvironment: 'offline' }));
  await writeFile(path.join(project, '.azure', 'offline', '.env'), [
    'AZURE_ENV_NAME="offline"',
    'AZURE_SUBSCRIPTION_ID="11111111-1111-4111-8111-111111111111"',
    'AZURE_TENANT_ID="22222222-2222-4222-8222-222222222222"',
    'AZURE_LOCATION="eastus2"',
    'AZURE_RESOURCE_GROUP="rg-offline-fixture"',
    '',
  ].join('\n'));
  const marker = path.join(root, 'events.txt');
  const hook = (event) => ({
    shell: 'pwsh', interactive: false, continueOnError: false,
    run: `[IO.File]::AppendAllText($env:FIXTURE_MARKER, "${event}\\n")`,
  });
  await writeFile(path.join(project, 'azure.yaml'), JSON.stringify({
    name: 'shopstream-offline-fixture',
    services: {},
    hooks: { predeploy: hook('predeploy'), postdeploy: hook('postdeploy') },
  }));
  const proxyUrl = `http://127.0.0.1:${proxy.address().port}`;
  const env = {
    PATH: process.env.PATH,
    HOME: path.join(root, 'home'),
    USERPROFILE: path.join(root, 'home'),
    TMPDIR: root, TEMP: root, TMP: root,
    AZURE_CONFIG_DIR: path.join(root, 'azure'),
    AZD_CONFIG_DIR: path.join(root, 'azd'),
    AZD_NON_INTERACTIVE: 'true',
    AZURE_DEV_COLLECT_TELEMETRY: 'no',
    DOTNET_CLI_TELEMETRY_OPTOUT: '1',
    HTTPS_PROXY: proxyUrl, HTTP_PROXY: proxyUrl, ALL_PROXY: proxyUrl, NO_PROXY: '',
    https_proxy: proxyUrl, http_proxy: proxyUrl, all_proxy: proxyUrl, no_proxy: '',
    FIXTURE_MARKER: marker,
  };
  const run = async (args) => {
    try {
      return { ...(await execute('azd', ['-C', project, '-e', 'offline', '--no-prompt', ...args], {
        env, timeout: 30000, maxBuffer: 1024 * 1024,
      })), code: 0 };
    } catch (error) {
      return { code: error.code, stdout: error.stdout || '', stderr: error.stderr || '' };
    }
  };
  const explicit = await run(['hooks', 'run', 'predeploy']);
  assert.equal(explicit.code, 0, explicit.stdout + explicit.stderr);
  assert.match(await readFile(marker, 'utf8'), /predeploy/);
  const explicitRequests = [...requests];
  await writeFile(marker, '');
  const deploy = await run(['deploy', '--all']);
  const events = await readFile(marker, 'utf8');
  t.diagnostic(JSON.stringify({ explicitHook: explicit.code, emptyServiceDeploy: deploy.code,
    predeploy: events.includes('predeploy'), postdeploy: events.includes('postdeploy'),
    explicitBlockedHosts: [...new Set(explicitRequests)], blockedHosts: [...new Set(requests)] }));
  if (deploy.code !== 0 || !events.includes('postdeploy')) {
    t.diagnostic('Native empty-service deploy is not qualified; use explicit hooks run predeploy.');
    t.diagnostic((deploy.stdout + deploy.stderr).slice(-1800));
  }
  assert.ok(explicitRequests.every((host) => host === 'aka.ms'),
    'Only blocked azd update checks are expected for the explicit hook');
});
