// REMOTE bundle config for the api-docs micro-frontend (native-federation
// remote name "apidocs"). The hugmesh.systems host consumes the exposed
// `./routes` module via loadRemoteModule({ remoteName: 'apidocs', exposedModule:
// './routes' }) and mounts API_DOCS_ROUTES at /admin/docs (adminGuard) — so the
// remote name and the exposed module keys MUST stay unchanged or the host's
// admin API-docs console breaks.
//
// Both host contracts are served from this single image:
//   ./routes        → API_DOCS_ROUTES (the .systems `./routes`+`*_ROUTES`
//                     loadChildren contract; DocsShell mounted at path '')
//   ./DocsShell      → the navigator-style /admin/docs root (games-style
//                      per-component loadRemote contract)
//   ./ApiExplorer    → try-it-out + auth-token override + SSE terminal
//   ./ApiReference   → read-only reference rendered from the OpenAPI spec
//
// The shared-deps surface + RxJS skip list live in ./federation-base.js so a
// change to the federation contract lands in one file, consistent with the host
// and every other HugMesh remote (games convention).
const { hugmeshRemote } = require('./federation-base');

module.exports = hugmeshRemote({
  name: 'apidocs',
  exposes: {
    './routes': './src/app/api-docs.routes.ts',
    './DocsShell': './src/app/docs-shell/docs-shell.component.ts',
    './ApiExplorer': './src/app/api-explorer/api-explorer.component.ts',
    './ApiReference': './src/app/api-reference/api-reference.component.ts',
  },
});
