import { Routes } from '@angular/router';
import { DocsShellComponent } from './docs-shell/docs-shell.component';

/**
 * Routes exposed by the api-docs native-federation remote (exposed module
 * `./routes`). The hugmesh.systems host mounts these at /admin/docs behind
 * its adminGuard (Casdoor 'admin' role) via the REMOTE_ROUTES loadChildren
 * contract, so the only path resolves to /admin/docs — the platform OpenAPI
 * navigator. Admin gating is enforced at the host AND by each service's
 * springdoc /v3/api-docs (ROLE_ADMIN in prod) — defense in depth.
 */
export const API_DOCS_ROUTES: Routes = [
  { path: '', component: DocsShellComponent },
];
