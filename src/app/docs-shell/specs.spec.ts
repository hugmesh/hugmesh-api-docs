import { assetsAnchor, assetsBaseFrom } from '../assets-base';
import { SPECS, SPEC_IDS } from './specs';
import adminSpec from '../../assets/specs/openapi-admin.json';
import modSpec from '../../assets/specs/openapi-mod.json';
import userSpec from '../../assets/specs/openapi-user.json';
import wikiSpec from '../../assets/specs/openapi-wiki.json';

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

/**
 * The committed spec is what the navigator loads first, with no running
 * service. The loader treats an `x-stub` marker or an empty `paths` as "no
 * contract" and goes live, so a committed spec that regresses to a stub would
 * silently put that service back on the live fetch. These four are copies of
 * the specs the backends commit; federation and actions have no committed
 * backend spec yet and stay stubs until a live capture.
 */
describe('committed backend specs carry operations', () => {
  const HTTP_METHODS = ['get', 'post', 'put', 'delete', 'patch'];
  const COMMITTED: Record<string, any> = {
    admin: adminSpec,
    mod: modSpec,
    user: userSpec,
    wiki: wikiSpec,
  };

  for (const [id, spec] of Object.entries(COMMITTED)) {
    it(`${id} is not a stub and has at least one operation`, () => {
      expect(spec['x-stub']).toBeUndefined();
      const paths: Record<string, Record<string, unknown>> = spec.paths ?? {};
      const operations = Object.values(paths).flatMap((item) =>
        Object.keys(item).filter((m) => HTTP_METHODS.includes(m)),
      );
      expect(operations.length).toBeGreaterThan(0);
    });
  }

  it('covers only ids the service picker offers', () => {
    for (const id of Object.keys(COMMITTED)) {
      expect(SPEC_IDS).toContain(id as (typeof SPEC_IDS)[number]);
    }
  });
});
