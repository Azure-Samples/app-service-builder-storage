import { cpSync, mkdirSync } from 'node:fs';
import path from 'node:path';

const destination = process.env.DESTINATION_DIR;
if (!destination || !path.isAbsolute(destination) || path.resolve(destination) === process.cwd()) {
  throw new Error('DESTINATION_DIR must be an absolute output directory outside the component source root.');
}
mkdirSync(destination, { recursive: true });
cpSync('dist', path.join(destination, 'dist'), { recursive: true });
