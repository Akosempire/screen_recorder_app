// Loads .env.local then .env (e.g. from `vercel env pull .env.local`) for local scripts.
// Real environment variables always win. Vercel sets env itself, so the API never needs this.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');

export function loadEnvFiles() {
  for (const name of ['.env.local', '.env']) {
    const file = path.join(root, name);
    if (fs.existsSync(file)) process.loadEnvFile(file);
  }
}
