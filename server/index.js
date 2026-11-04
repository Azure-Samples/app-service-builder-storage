const { createApp } = require('./app');
const { createContainerClient } = require('./storage');

const mode = process.env.APP_ACCESS_MODE || 'builder';
if (!['local', 'builder'].includes(mode)) throw new Error('APP_ACCESS_MODE must be builder or local.');
const host = mode === 'local' ? '127.0.0.1' : '0.0.0.0';
const port = Number(process.env.PORT || 8080);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT must be between 1 and 65535.');
const server = createApp({ container: createContainerClient(), mode }).listen(port, host, () => {
  console.log(`FileVault listening on ${host}:${port} (${mode} access).`);
});
server.requestTimeout = 60000;
server.headersTimeout = 10000;
