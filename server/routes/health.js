const router = require('express').Router();
router.get('/api/health', (req, res) => res.json({ status: 'healthy', service: 'filevault' }));
module.exports = router;
