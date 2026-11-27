import { mkdir, writeFile, access, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const dist = fileURLToPath(new URL('../dist/', import.meta.url));
const cjs = fileURLToPath(new URL('../dist/cjs/', import.meta.url));

await mkdir(cjs, { recursive: true });
await writeFile(`${cjs}package.json`, `${JSON.stringify({ type: 'commonjs' }, null, 2)}\n`, 'utf8');

// `.d.ts` inputs are not emitted by tsc, but keep the published tree clean if
// a future TypeScript version starts copying them.
for (const candidate of [`${dist}shims.d.ts`, `${cjs}shims.d.ts`]) {
  try {
    await access(candidate);
    await rm(candidate, { force: true });
  } catch {
    // Not present: nothing to do.
  }
}
