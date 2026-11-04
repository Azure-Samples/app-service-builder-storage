const { execFileSync } = require('node:child_process');
const { cpSync, mkdirSync } = require('node:fs');
const path = require('node:path');

const destination = process.env.DESTINATION_DIR;
if (!destination || !path.isAbsolute(destination) || path.resolve(destination) === process.cwd()) {
  throw new Error('DESTINATION_DIR must be an absolute output directory outside the component source root.');
}
mkdirSync(destination, { recursive: true });
for (const entry of ['index.js', 'app.js', 'storage.js', 'routes', 'package.json', 'package-lock.json']) {
  cpSync(entry, path.join(destination, entry), { recursive: true });
}
execFileSync('npm', ['ci', '--omit=dev'], { cwd: destination, stdio: 'inherit' });
