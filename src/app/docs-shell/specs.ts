import { resolveAssetsBase } from '../assets-base';

/**
 * The platform OpenAPI specs the navigator can browse. This is the SERVICE
 * PICKER source of truth — each entry is one Spring service that publishes a
 * springdoc /v3/api-docs spec.
 *
 * `primary`  — the build-time-committed spec artifact under this remote's
 *              static assets (src/assets/specs/openapi-<svc>.json). Captured
 *              offline by `npm run gen:fetch:<svc>` against a dev-profile
 *              instance (where /v3/api-docs is permitAll), or shipped as a small
 *              committed STUB (info + empty paths) so the build is green and the
 *              picker renders before a real capture lands.
 *              The URL is ABSOLUTE and anchored on this module's own chunk
 *              (see ../assets-base.ts): a root-absolute '/assets/...' 404s on
 *              the host shell's origin when federated (hugmesh-api-docs#10).
 * `fallback` — the LIVE /v3/api-docs reachable through the host/gateway proxy.
 *              Works in dev/test (permitAll); in prod it requires ROLE_ADMIN,
 *              carried by the session cookie that the HttpClient credentials
 *              interceptor attaches to this request. The
 *              gateway per-service proxy prefix is a documented host follow-up
 *              (the be-gateway currently has a single catch-all, not a
 *              per-service /v3/api-docs fan-out), so the prefix below is the
 *              intended service-relative path the host nginx/gateway resolves.
 *
 * Ports for reference: all BFFs + federation-api on 8080; hugmesh-actions on
 * 8090. No service sets a context-path, so the spec is at the bare /v3/api-docs.
 */
export interface SpecConfig {
  readonly label: string;
  readonly primary: string;
  readonly fallback: string;
}

export const SPECS = {
  admin: {
    label: 'Admin BFF',
    primary: resolveAssetsBase('assets/specs/openapi-admin.json'),
    fallback: '/bff/admin/v3/api-docs',
  },
  mod: {
    label: 'Mod BFF',
    primary: resolveAssetsBase('assets/specs/openapi-mod.json'),
    fallback: '/bff/mod/v3/api-docs',
  },
  user: {
    label: 'User BFF',
    primary: resolveAssetsBase('assets/specs/openapi-user.json'),
    fallback: '/bff/user/v3/api-docs',
  },
  federation: {
    label: 'Federation API',
    primary: resolveAssetsBase('assets/specs/openapi-federation.json'),
    fallback: '/api/federation/v3/api-docs',
  },
  actions: {
    label: 'HugMesh Actions',
    primary: resolveAssetsBase('assets/specs/openapi-actions.json'),
    fallback: '/actions/v3/api-docs',
  },
  wiki: {
    label: 'Wiki BFF',
    primary: resolveAssetsBase('assets/specs/openapi-wiki.json'),
    fallback: '/bff/wiki/v3/api-docs',
  },
} as const satisfies Record<string, SpecConfig>;

export type SpecId = keyof typeof SPECS;

/** Declaration order is the order shown in the service picker. */
export const SPEC_IDS = Object.keys(SPECS) as SpecId[];
