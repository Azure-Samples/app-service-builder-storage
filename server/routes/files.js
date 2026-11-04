const { Router } = require('express');
const multer = require('multer');
const { randomUUID } = require('node:crypto');
const { pipeline } = require('node:stream/promises');

const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;
const PREVIEW_TYPES = new Set(['image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/avif']);

function badRequest(message) {
  return Object.assign(new Error(message), { status: 400 });
}

function validateKey(key) {
  if (typeof key !== 'string' || !key || key.length > 1024 || /[\x00-\x1f\x7f]/.test(key)) {
    throw badRequest('Invalid blob name.');
  }
  return key;
}

function createFilesRouter(container) {
  const router = Router();
  const upload = multer({
    storage: multer.memoryStorage(),
    limits: { fileSize: MAX_UPLOAD_BYTES, files: 1, fields: 0, parts: 1 },
  });
  router.use((req, res, next) => {
    res.setHeader('Cache-Control', 'no-store');
    if (['POST', 'DELETE'].includes(req.method) && req.get('X-FileVault-Request') !== '1') {
      return res.status(403).json({ error: 'A same-origin FileVault request is required.' });
    }
    next();
  });

  router.get('/', async (req, res, next) => {
    try {
      const { prefix = '', continuationToken, pageSize = '100' } = req.query;
      if (typeof prefix !== 'string' || prefix.length > 256 ||
          (continuationToken !== undefined && (typeof continuationToken !== 'string' || continuationToken.length > 4096)) ||
          typeof pageSize !== 'string' || !/^\d+$/.test(pageSize) ||
          Number(pageSize) < 1 || Number(pageSize) > 100) {
        throw badRequest('Use a prefix of at most 256 characters and a pageSize between 1 and 100.');
      }
      const pages = container.listBlobsFlat({ prefix, abortSignal: AbortSignal.timeout(30000) }).byPage({
        maxPageSize: Number(pageSize), continuationToken,
      });
      const page = await pages.next();
      const segment = page.value;
      res.json({
        blobs: (segment?.segment.blobItems || []).map(blob => ({
          key: blob.name,
          sizeBytes: blob.properties.contentLength,
          contentType: blob.properties.contentType,
          lastModified: blob.properties.lastModified,
        })),
        continuationToken: segment?.continuationToken || null,
      });
    } catch (err) { next(err); }
  });

  router.post('/', upload.single('file'), async (req, res, next) => {
    try {
      if (!req.file) throw badRequest('Select one file of at most 10 MiB.');
      const name = req.file.originalname.replace(/[^a-zA-Z0-9._-]/g, '_').slice(-200) || 'file';
      const key = randomUUID() + '-' + name;
      const contentType = req.file.mimetype || 'application/octet-stream';
      await container.getBlockBlobClient(key).uploadData(req.file.buffer, {
        conditions: { ifNoneMatch: '*' },
        blobHTTPHeaders: { blobContentType: contentType },
        concurrency: 2,
        abortSignal: AbortSignal.timeout(30000),
      });
      res.status(201).json({ key, sizeBytes: req.file.size, contentType });
    } catch (err) { next(err); }
  });

  router.get('/:key(*)', async (req, res, next) => {
    try {
      const key = validateKey(req.params.key);
      const signal = AbortSignal.timeout(30000);
      const download = await container.getBlobClient(key).download(0, undefined, { abortSignal: signal });
      if (!download.readableStreamBody) throw new Error('Blob download did not return a stream.');
      const inline = req.query.preview === '1' && PREVIEW_TYPES.has(download.contentType);
      res.setHeader('Content-Type', inline ? download.contentType : 'application/octet-stream');
      res.setHeader('Content-Disposition', `${inline ? 'inline' : 'attachment'}; filename="${key.split('/').pop().replace(/[^a-zA-Z0-9._-]/g, '_').slice(-200)}"`);
      res.setHeader('Content-Security-Policy', "default-src 'none'; sandbox");
      if (download.contentLength !== undefined) res.setHeader('Content-Length', download.contentLength);
      await pipeline(download.readableStreamBody, res, { signal });
    } catch (err) { next(err); }
  });

  router.delete('/:key(*)', async (req, res, next) => {
    try {
      const key = validateKey(req.params.key);
      const result = await container.getBlobClient(key).deleteIfExists({ abortSignal: AbortSignal.timeout(30000) });
      if (!result.succeeded) return res.status(404).json({ error: 'File not found.' });
      res.json({ deleted: true, key });
    } catch (err) { next(err); }
  });
  return router;
}

module.exports = { createFilesRouter, MAX_UPLOAD_BYTES };
