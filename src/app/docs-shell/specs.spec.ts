import { assetsAnchor, assetsBaseFrom } from '../assets-base';
import { SPECS, SPEC_IDS } from './specs';

/** Any absolute URL (has a scheme). Karma rewrites `import.meta.url` to a
 *  `file://` source URL; the shipped bundle keeps the real chunk URL. */
const ABSOLUTE_URL = /^[a-z][a-z0-9+.-]*:\/\//i;

/**
 * Regression guard for hugmesh-api-docs#10: under the host shell the document
 * is the SHELL (`<base href="/">`), so a root-absolute or document-relative
 * primary spec URL resolves at the shell root and 404s. The primary URL must be
 * anchored on this remote's own module chunk.
 */
describe('SPECS primary artifact URLs (federated mount, #10)', () => {
  const SHELL_DOC = 'https://mesh.example/admin/docs';
  const REMOTE_CHUNK = 'https://mesh.example/api-docs/chunk-ABC12345.js';
  const STANDALONE_CHUNK = 'https://docs.mesh.example/chunk-ABC12345.js';

  it('resolves against the remote chunk when mounted under /api-docs', () => {
    expect(assetsBaseFrom(REMOTE_CHUNK, 'assets/specs/openapi-admin.json'))
      .toBe('https://mesh.example/api-docs/assets/specs/openapi-admin.json');
    // What the old root-absolute string did: the shell root, the observed 404.
    expect(new URL('/assets/specs/openapi-admin.json', SHELL_DOC).href)
      .toBe('https://mesh.example/assets/specs/openapi-admin.json');
    // A merely relative string does not escape the document either.
    expect(new URL('./assets/specs/openapi-admin.json', 'https://mesh.example/').href)
      .toBe('https://mesh.example/assets/specs/openapi-admin.json');
  });

  it('still resolves inside the remote when served standalone at the origin root', () => {
    expect(assetsBaseFrom(STANDALONE_CHUNK, 'assets/specs/openapi-admin.json'))
      .toBe('https://docs.mesh.example/assets/specs/openapi-admin.json');
  });

  it('every primary is absolute, anchored on the module, and keeps its file name', () => {
    expect(assetsAnchor()).toMatch(ABSOLUTE_URL);
    for (const id of SPEC_IDS) {
      const primary: string = SPECS[id].primary;
      expect(primary).toMatch(ABSOLUTE_URL);
      expect(primary.startsWith('/')).toBeFalse();
      expect(primary.endsWith(`/assets/specs/openapi-${id}.json`)).toBeTrue();
    }
  });
});
