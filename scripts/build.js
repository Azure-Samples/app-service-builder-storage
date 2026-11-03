const { execFileSync } = require('node:child_process');
const { mkdirSync } = require('node:fs');
const path = require('node:path');

const destination = process.env.DESTINATION_DIR;
if (!destination || !path.isAbsolute(destination)) {
  throw new Error('DESTINATION_DIR must be an absolute Builder output directory.');
}
if (path.resolve(destination) === process.cwd()) {
  throw new Error('Build output must not overwrite source.');
}
mkdirSync(destination, { recursive: true });
for (const component of ['client', 'server']) {
  execFileSync('npm', ['--prefix', component, 'run', 'build:builder'], {
    env: { ...process.env, DESTINATION_DIR: path.join(destination, component) },
    stdio: 'inherit',
  });
}
