# hugmesh-api-docs

An admin-gated API documentation browser for [HugMesh](https://github.com/hugmesh-net) — an
Angular native-federation remote built on a custom OpenAPI navigator (not a generic Swagger UI).

## Highlights

- **Service picker.** Choose which backend service's OpenAPI spec to browse from a single shell.
- **Two views per spec.** A read-only **Reference** tab (endpoints, parameters, request/response
  samples) and an interactive **Try it out** tab (live request form, JSON/multipart body editor,
  and a terminal-styled viewer for streaming/SSE endpoints).
- **Resilient spec loading.** Each service's spec is loaded committed-artifact-first, falling back
  to a live fetch from the running service, with an honest "not yet published" state if neither is
  available — never a silently empty page.
- **Spec extensions.** Services can annotate their OpenAPI documents with a small set of
  `x-hugmesh` extension keys (sample requests/responses, streaming hints, upload field names) to
  improve how the navigator renders them.
- **Session-based auth.** Live requests ride the platform's httpOnly `bff_` session cookie — the
  gateway exchanges it for the upstream bearer server-side, so the browser never holds a token. A
  manual bearer override is available for probing another environment.
- **No backend of its own.** Pure frontend viewer — no database, no identity-provider client, no
  tenant logic. Authorization for the live calls it makes is enforced entirely by the services it
  browses.

## Local development

```sh
nvm use 24
npm ci
npm start        # serves standalone at http://localhost:4207
npm test
npm run build    # -> dist/api-docs/browser
```

### Generating a typed client (optional)

```sh
npm run gen      # ng-openapi-gen, reads a committed openapi.json
```

## Deploy

The Dockerfile builds a `node:24-alpine` build stage and serves the compiled bundle via
`nginx:1.27-alpine`, with CORS enabled so a host shell can fetch `remoteEntry.json` cross-origin,
and a `/healthz` endpoint for readiness probes.

## Roadmap

- Bring this remote's build pipeline in line with the platform's standard security-scanning stages
  (currently build-only).
- Grow the set of committed example specs as backend services publish real OpenAPI captures.

## License

MIT — see [LICENSE](LICENSE).
