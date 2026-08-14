import { API_DOCS_ROUTES } from './api-docs.routes';
import { DocsShellComponent } from './docs-shell/docs-shell.component';

/**
 * API_DOCS_ROUTES is the `./routes` federation surface the hugmesh.net
 * host mounts at /admin/docs (loadChildren). Pin the contract so a rename can't
 * silently break the host wiring.
 */
describe('API_DOCS_ROUTES', () => {
  it('exposes the DocsShell at the empty path', () => {
    expect(API_DOCS_ROUTES.length).toBe(1);
    expect(API_DOCS_ROUTES[0].path).toBe('');
    expect(API_DOCS_ROUTES[0].component).toBe(DocsShellComponent);
  });
});
