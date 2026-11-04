const express = require('express');
const path = require('node:path');
const { createFilesRouter } = require('./routes/files');

function createApp({ container, mode = 'builder', distPath = path.join(__dirname, '..', 'client', 'dist') }) {
  if (!['local', 'builder'].includes(mode)) throw new Error('Invalid access mode.');
  const app = express();
  app.disable('x-powered-by');
  app.use((req, res, next) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'same-origin');
    next();
  });
  app.use('/', require('./routes/health'));
  app.use((req, res, next) => {
    // Builder strips spoofed identity headers; local mode binds only to loopback.
    if (mode === 'builder' && !req.get('X-MS-CLIENT-PRINCIPAL-ID')) {
      return res.status(401).json({ error: 'Sign in through Builder. Required sign-in must be configured before using FileVault.' });
    }
    next();
  });
  app.use('/api/files', createFilesRouter(container));
  app.use('/api', (req, res) => res.status(404).json({ error: 'API route not found.' }));
  app.use(express.static(distPath));
  app.get('*', (req, res, next) => {
    res.sendFile(path.join(distPath, 'index.html'), err => { if (err) next(err); });
  });
  app.use((err, req, res, next) => {
    console.error('FileVault request failed', { method: req.method, code: err.code, status: err.statusCode || err.status, message: err.message });
    if (res.headersSent) return res.destroy(err);
    if (err.code === 'LIMIT_FILE_SIZE') return res.status(413).json({ error: 'Maximum file size is 10 MiB.' });
    if (err.name === 'MulterError') return res.status(400).json({ error: 'Upload exactly one file without extra fields.' });
    if (err.status === 400) return res.status(400).json({ error: err.message });
    if (err.statusCode === 400) return res.status(400).json({ error: 'Storage rejected this request. Refresh the file list and check the supplied parameters.' });
    if (err.statusCode === 404) return res.status(404).json({ error: 'File or storage container not found.' });
    if (err.statusCode === 403 || err.statusCode === 401) {
      return res.status(503).json({ error: 'Storage access denied. Check managed identity, container RBAC and network access.' });
    }
    res.status(502).json({ error: 'FileVault could not complete the request. Check the server logs and retry.' });
  });
  return app;
}

module.exports = { createApp };
