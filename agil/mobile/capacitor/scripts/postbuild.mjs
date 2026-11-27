import { mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const cjs = fileURLToPath(new URL('../dist/cjs/', import.meta.url));
await mkdir(cjs, { recursive: true });
await writeFile(`${cjs}package.json`, `${JSON.stringify({ type: 'commonjs' }, null, 2)}\n`, 'utf8');
