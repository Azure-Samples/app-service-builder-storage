const { test } = require('node:test');
const assert = require('node:assert/strict');
const { Readable } = require('node:stream');
const { createApp } = require('../server/app');
const { createContainerClient } = require('../server/storage');

async function withServer(run, { mode = 'local', container } = {}) {
  const blobs = new Map();
  let listCalls = 0;
  const fake = {
    listBlobsFlat(options) {
      listCalls++;
      return { byPage({ maxPageSize, continuationToken }) {
        const items = [...blobs].filter(([name]) => name.startsWith(options.prefix));
        const offset = Number(continuationToken || 0);
        const blobItems = items.slice(offset, offset + maxPageSize).map(([name, value]) => ({
          name, properties: { contentLength: value.body.length, contentType: value.contentType },
        }));
        return (async function* () {
          yield { segment: { blobItems }, continuationToken: offset + maxPageSize < items.length ? String(offset + maxPageSize) : '' };
        })();
      } };
    },
    getBlockBlobClient(key) {
      return { async uploadData(body, options) {
        assert.equal(options.conditions.ifNoneMatch, '*');
        blobs.set(key, { body, contentType: options.blobHTTPHeaders.blobContentType });
      } };
    },
    getBlobClient(key) {
      return {
        async download() {
          const value = blobs.get(key);
          if (!value) throw Object.assign(new Error('Missing'), { statusCode: 404 });
          return { readableStreamBody: Readable.from(value.body), contentType: value.contentType, contentLength: value.body.length };
        },
        async deleteIfExists() { return { succeeded: blobs.delete(key) }; },
      };
    },
  };
  const server = createApp({ container: container || fake, mode }).listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  const url = `http://127.0.0.1:${server.address().port}`;
  try { await run({ url, blobs, listCalls: () => listCalls }); }
  finally { await new Promise(resolve => server.close(resolve)); }
}

async function upload(url, content = 'hello', type = 'text/plain') {
  const body = new FormData();
  body.append('file', new Blob([content], { type }), 'example.txt');
  return fetch(url + '/api/files', { method: 'POST', headers: { 'X-FileVault-Request': '1' }, body });
}

test('upload, paged list, byte-exact download and delete through backend', async () => {
  await withServer(async ({ url }) => {
    const first = await upload(url);
    assert.equal(first.status, 201);
    const { key } = await first.json();
    assert.match(key, /^[a-f0-9-]+-example\.txt$/);
    await upload(url, 'second');
    const page = await (await fetch(url + '/api/files?pageSize=1')).json();
    assert.equal(page.blobs.length, 1);
    assert.ok(page.continuationToken);
    const next = await (await fetch(url + '/api/files?pageSize=1&continuationToken=' + page.continuationToken)).json();
    assert.equal(next.blobs.length, 1);
    assert.notEqual(next.blobs[0].key, page.blobs[0].key);
    assert.equal(next.continuationToken, null);
    const download = await fetch(url + '/api/files/' + encodeURIComponent(key));
    assert.equal(await download.text(), 'hello');
    assert.match(download.headers.get('content-disposition'), /^attachment/);
    assert.equal(download.headers.get('cache-control'), 'no-store');
    const deletion = await fetch(url + '/api/files/' + key, { method: 'DELETE', headers: { 'X-FileVault-Request': '1' } });
    assert.equal(deletion.status, 200);
    assert.equal((await fetch(url + '/api/files/' + key)).status, 404);
    assert.equal((await fetch(url + '/api/files/' + key, { method: 'DELETE', headers: { 'X-FileVault-Request': '1' } })).status, 404);
  });
});

test('Builder access fails closed without verified identity; health remains reachable', async () => {
  await withServer(async ({ url, listCalls }) => {
    assert.equal((await fetch(url + '/api/files')).status, 401);
    assert.equal((await fetch(url + '/')).status, 401);
    assert.equal((await fetch(url + '/api/health')).status, 200);
    assert.equal((await fetch(url + '/health')).status, 401);
    assert.equal(listCalls(), 0);
    assert.equal((await fetch(url + '/api/files', { headers: { 'X-MS-CLIENT-PRINCIPAL-ID': 'test' } })).status, 200);
  }, { mode: 'builder' });
});

test('reject invalid pagination, oversized upload, extra fields and unguarded mutation', async () => {
  await withServer(async ({ url, listCalls }) => {
    for (const query of ['pageSize=0', 'pageSize=101', 'pageSize=1.5', 'prefix[a]=b', 'continuationToken=' + 'a'.repeat(4097)]) {
      assert.equal((await fetch(url + '/api/files?' + query)).status, 400);
    }
    assert.equal(listCalls(), 0);
    assert.equal((await fetch(url + '/api/files', { method: 'POST' })).status, 403);
    assert.equal((await upload(url, new Uint8Array(10 * 1024 * 1024 + 1))).status, 413);
    const body = new FormData();
    body.append('other', 'field');
    assert.equal((await fetch(url + '/api/files', { method: 'POST', headers: { 'X-FileVault-Request': '1' }, body })).status, 400);
    const empty = new FormData();
    assert.equal((await fetch(url + '/api/files', { method: 'POST', headers: { 'X-FileVault-Request': '1' }, body: empty })).status, 400);
  });
});

test('preview only raster images; HTML and SVG always download', async () => {
  await withServer(async ({ url }) => {
    for (const type of ['image/png', 'image/svg+xml', 'text/html']) {
      const { key } = await (await upload(url, 'content', type)).json();
      const response = await fetch(url + '/api/files/' + key + '?preview=1');
      assert.equal(response.headers.get('content-type'), type === 'image/png' ? type : 'application/octet-stream');
      assert.match(response.headers.get('content-disposition'), type === 'image/png' ? /^inline/ : /^attachment/);
      assert.match(response.headers.get('content-security-policy'), /sandbox/);
    }
  });
});

test('allow exactly 10 MiB and empty files without base64 expansion', async () => {
  await withServer(async ({ url }) => {
    for (const size of [0, 10 * 1024 * 1024]) {
      const response = await upload(url, new Uint8Array(size));
      assert.equal(response.status, 201);
      const result = await response.json();
      assert.equal(result.sizeBytes, size);
      const download = await fetch(url + '/api/files/' + result.key);
      assert.equal((await download.arrayBuffer()).byteLength, size);
    }
  });
});

test('storage permission failures stay explicit and do not leak service details', async () => {
  await withServer(async ({ url }) => {
    const response = await fetch(url + '/api/files');
    assert.equal(response.status, 503);
    const data = await response.json();
    assert.match(data.error, /managed identity/);
    assert.ok(!data.error.includes('sensitive'));
  }, { container: { listBlobsFlat() { throw Object.assign(new Error('sensitive service details'), { statusCode: 403 }); } } });
});

test('configuration rejects non-Azure endpoints, SAS and invalid containers', () => {
  for (const endpoint of ['http://example.org', 'https://acct.blob.core.windows.net?sig=secret', 'https://acct.blob.core.windows.net/other']) {
    assert.throws(() => createContainerClient({ AZURE_STORAGE_BLOB_ENDPOINT: endpoint, AZURE_STORAGE_CONTAINER: 'files' }));
  }
  assert.throws(() => createContainerClient({ AZURE_STORAGE_BLOB_ENDPOINT: 'https://acct.blob.core.windows.net', AZURE_STORAGE_CONTAINER: 'not--valid' }));
  const client = createContainerClient({ AZURE_STORAGE_BLOB_ENDPOINT: 'https://acct.blob.core.windows.net', AZURE_STORAGE_CONTAINER: 'files', APP_ACCESS_MODE: 'local' });
  assert.equal(client.containerName, 'files');
});
