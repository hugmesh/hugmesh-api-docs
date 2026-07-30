import { inject } from '@angular/core';
import { CanActivateFn, Router } from '@angular/router';
import { SessionService } from './session.service';

/**
 * Route guard that restricts access to the API-docs micro-frontend to users
 * holding the `admin` Casdoor role.
 *
 * Not wired into `API_DOCS_ROUTES` or any other route in this repo — gating
 * for the federated remote is enforced at the host (and by each service's
 * springdoc `/v3/api-docs`), per `API_DOCS_ROUTES`'s own comment. This guard
 * exists solely so the standalone dev shell (`AppComponent`, served outside
 * the host) has an equivalent admin check to exercise/develop against.
 *
 * Returns `true` to allow navigation, or redirects to `/login` when the
 * session either does not exist or does not include the admin role.
 *
 * @see SessionService.isAdmin
 */
export const adminGuard: CanActivateFn = () => {
  const session = inject(SessionService);
  const router = inject(Router);
  // Allow if the current session carries the admin role.
  if (session.isAdmin()) return true;
  // No admin role — redirect to the login page instead of activating the route.
  return router.parseUrl('/login');
};
