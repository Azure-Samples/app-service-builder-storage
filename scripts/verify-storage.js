const { randomUUID } = require('node:crypto');
const assert = require('node:assert/strict');

async function verify() {
  const origin = new URL(process.env.FILEVAULT_URL || 'http://127.0.0.1:8080');
  if (origin.protocol !== 'https:' && !(origin.protocol === 'http:' && ['127.0.0.1', 'localhost'].includes(origin.hostname))) {
    throw new Error('Use a hosted HTTPS FileVault URL or loopback HTTP.');
  }
  if (origin.username || origin.password || origin.search || origin.hash || origin.pathname !== '/') {
    throw new Error('FILEVAULT_URL must be a clean app origin, without credentials.');
  }
  const headers = process.env.FILEVAULT_SESSION_COOKIE ? { Cookie: process.env.FILEVAULT_SESSION_COOKIE } : {};
  const request = async (path, options = {}) => {
    const response = await fetch(new URL(path, origin), {
      ...options, headers: { ...headers, ...options.headers }, redirect: 'manual', signal: AbortSignal.timeout(30000),
    });
    if (!response.ok) throw new Error(`FileVault operation failed: HTTP ${response.status}. Check sign-in, identity, RBAC and logs.`);
    return response;
  };
  // A read must succeed before introducing test data.
  const before = await (await request('/api/files?pageSize=1')).json();
  assert.ok(Array.isArray(before.blobs));
  const payload = Buffer.from('FileVault verification ' + randomUUID());
  const body = new FormData();
  body.append('file', new Blob([payload], { type: 'text/plain' }), 'qualification.txt');
  const result = await (await request('/api/files', { method: 'POST', headers: { 'X-FileVault-Request': '1' }, body })).json();
  let deleted = false;
  try {
    assert.equal(result.sizeBytes, payload.length);
    const listing = await (await request('/api/files?prefix=' + encodeURIComponent(result.key))).json();
    assert.equal(listing.blobs[0].key, result.key);
    const downloaded = await request('/api/files/' + encodeURIComponent(result.key));
    assert.deepEqual(Buffer.from(await downloaded.arrayBuffer()), payload);
    await request('/api/files/' + encodeURIComponent(result.key), { method: 'DELETE', headers: { 'X-FileVault-Request': '1' } });
    deleted = true;
    const after = await (await request('/api/files?prefix=' + encodeURIComponent(result.key))).json();
    assert.equal(after.blobs.length, 0);
    console.log(JSON.stringify({ origin: origin.origin, list: true, upload: true, downloadByteMatch: true, delete: true, remainingTestFiles: 0 }));
  } finally {
    if (!deleted) {
      await request('/api/files/' + encodeURIComponent(result.key), { method: 'DELETE', headers: { 'X-FileVault-Request': '1' } });
    }
  }
}

verify().catch(error => {
  console.error(error.message);
  process.exitCode = 1;
});
