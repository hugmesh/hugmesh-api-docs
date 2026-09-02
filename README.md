# hugmesh-api-docs

An admin-gated API documentation browser for [HugMesh](https://github.com/hugmesh) — an
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

## Security scanning

The pipeline carries the platform's standard OWASP pen-test stage, pulled from the generator
(`tests/pentest/ci/pentest-stage.gitlab-ci.yml`) so there is one source of truth for every
onboarded repo:

| job | what it does |
| --- | --- |
| `pentest:sca` | OWASP Dependency-Check over this repo's own manifests, `--failOnCVSS 7`, SARIF into the MR security widget. |
| `pentest:dast` | Authenticated ZAP baseline + custom probes + the committed nuclei boundary templates, via the shared harness. |

Both are `allow_failure: true` **by design** — a finding must never red an onboarded repo's
pipeline; findings land in the archived `out/pentest` scorecard and SARIF for triage. An *absent*
scan is not a finding, though, which is the trap this repo is wired to avoid: the harness runs from
the including repo's checkout, so `pentest:dast` **fetches** it from the generator at CI time
(depth-1 clone of the same `main` the `include:` pins) rather than assuming a `tests/pentest/` this
repo does not have. `lint:ci-wiring` asserts that reachability on every push, and mutation-tests
itself so a green tick means the assertion can actually fail:

```sh
npm run check:ci-wiring   # assert this repo's pen-test wiring is not inert
npm run test:ci-wiring    # ...and prove the guard detects each way of breaking it
```

## Roadmap

- Grow the set of committed example specs as backend services publish real OpenAPI captures.

## License

MIT — see [LICENSE](LICENSE).
