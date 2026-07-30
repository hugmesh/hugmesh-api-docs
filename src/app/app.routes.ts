import { Routes } from '@angular/router';
import { API_DOCS_ROUTES } from './api-docs.routes';

/** Dev-shell routes: mount the exposed api-docs routes at the root so the remote
 *  is browsable standalone (`ng serve api-docs` at :4207). The host ignores this
 *  and loads `./routes` (API_DOCS_ROUTES). */
export const routes: Routes = [{ path: '', children: API_DOCS_ROUTES }];
