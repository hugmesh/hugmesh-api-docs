/**
 * Where this remote's own shipped `assets/` tree lives, as an ABSOLUTE URL.
 *
 * THE TRAP: a bare string like `'/assets/specs/openapi-admin.json'` (or even a
 * relative `'./assets/...'`) is resolved by HttpClient / `fetch()` against the
 * DOCUMENT's URL. Standalone that is harmless, because the document already is
 * the remote at the origin root. Federated into the host shell the document is
 * the SHELL (`<base href="/">`, route `/admin/docs`), so the path resolves to
 * `/assets/specs/openapi-admin.json` at the SHELL ROOT, where the host's nginx
 * answers 404. The file is really served at `/api-docs/assets/specs/...`.
 * (hugmesh-api-docs#10.)
 *
 * `import.meta.url` is the URL of the very chunk this module is bundled into,
 * which is served from the remote's own mount in BOTH cases (`/api-docs/...`
 * federated, `/` standalone). Anchoring on it needs no hardcoded mount path and
 * no build-time base href. `document.baseURI` is the fallback for a non-ESM
 * or test context.
 *
 * Same shape as `resolveAssetsBase()` in hugmesh-mastodon-ui
 * (`src/app/assets-base.ts`) and hugmesh-character-studio-ui.
 */

/** The anchor asset paths resolve against: this module's chunk URL. */
export function assetsAnchor(): string {
  return typeof import.meta?.url === 'string'
    ? import.meta.url
    : typeof document !== 'undefined'
      ? document.baseURI
      : '/';
}

/** Resolve `relative` against an explicit `anchor`. Pure, so tests need no shell. */
export function assetsBaseFrom(anchor: string, relative: string): string {
  try {
    // Chunks are emitted beside index.html, so the module's directory IS the
    // app root; new URL() normalises it into an absolute href.
    return new URL(relative, anchor).href;
  } catch {
    return relative;
  }
}

/** The absolute URL of `relative` (e.g. `'assets/specs/x.json'`) inside THIS remote. */
export function resolveAssetsBase(relative: string): string {
  return assetsBaseFrom(assetsAnchor(), relative);
}
