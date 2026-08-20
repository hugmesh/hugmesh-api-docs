import { HttpInterceptorFn } from '@angular/common/http';

/**
 * Attaches the HttpOnly session cookie to outbound HttpClient requests, so the
 * standalone dev shell's typed calls match the raw-fetch convention the rest of
 * the platform uses (`credentials: 'include'`):
 *
 *  - `withCredentials: true` ALWAYS — the id-gateway routes `/bff/*` and `/api/*`
 *    with the session cookie, so DocsShell's live `/v3/api-docs` fallback carries
 *    it. The gateway's BffCookieToBearerWebFilter exchanges that `bff_` cookie for
 *    the upstream bearer SERVER-SIDE, so the browser never holds (nor sends) a bearer.
 *
 * PUBLIC reads (the committed spec artifacts under /assets, permitAll) work for an
 * anonymous viewer because no cookie is present — the cookie carries auth when one
 * exists and is simply absent otherwise.
 *
 * Only wired by `src/bootstrap.ts` (`ng serve api-docs`). When federated into the
 * hugmesh.net host, DocsShell injects the HOST's HttpClient, which already applies
 * the equivalent `bearerInterceptor` app-wide.
 *
 * @see ApiExplorerComponent — the raw-`fetch()` try-it-out call sites set
 *      `credentials: 'include'` themselves rather than going through HttpClient.
 */
export const credentialsInterceptor: HttpInterceptorFn = (req, next) => {
  return next(req.clone({ withCredentials: true }));
};
