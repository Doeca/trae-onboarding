// An explicit login safety condition, NOT an enterprise compatibility layer
// or a network sandbox. In particular, this does not intercept node:http.
import { writeFileSync } from 'node:fs';

const blockedFetch = async () => {
  throw new Error('native_login_fetch_blocked');
};
Object.defineProperty(globalThis, 'fetch', {
  get: () => blockedFetch,
  // Native host installs its own fetch wrapper at startup. Accept assignment
  // without replacing the guard, so preloading cannot crash the host.
  set: () => {},
  configurable: false,
});
// Bun.fetch is read-only in the pinned runtime. The installed plugin uses
// global fetch; do not mutate Bun's intrinsic or claim to sandbox other APIs.
// No URLs, headers, bodies, credentials, or upstream error text are logged.
if (!process.env.NATIVE_MAGPIE_GUARD_MARKER || !process.env.NATIVE_MAGPIE_GUARD_NONCE) {
  throw new Error('native_login_guard_configuration_missing');
}
writeFileSync(process.env.NATIVE_MAGPIE_GUARD_MARKER,
  process.env.NATIVE_MAGPIE_GUARD_NONCE, { mode: 0o600, flag: 'wx' });
