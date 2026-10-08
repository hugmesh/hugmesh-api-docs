# hugmesh-api-docs

An admin-gated API documentation browser for [HugMesh](https://github.com/hugmesh) — an
Angular native-federation remote built on a custom OpenAPI navigator (not a generic Swagger UI).

## Highlights

- **Service picker.** Choose which backend service's OpenAPI spec to browse from a single shell:
  Admin BFF, Mod BFF, User BFF, Federation API, HugMesh Actions, Wiki BFF.
- **Two views per spec.** A read-only **Reference** tab (endpoints, parameters, request/response
  samples) and an interactive **Try it out** tab (live request form, JSON/multipart body editor,
  and a terminal-styled viewer for streaming/SSE endpoints).
- **Resilient spec loading.** Each service's spec is loaded committed-artifact-first, falling back
  to a live fetch from the running service, with an honest "not yet published" state if neither is
  available — never a silently empty page. A committed spec with no operations counts as missing.
  All six committed specs (`src/assets/specs/`) are stubs today, so the live fetch does the work.
- **Spec extensions.** Services can annotate their OpenAPI documents with a small set of
  `x-hugmesh` extension keys (`sampleRequest`, `sampleResponse`, `sampleEvent`, `sse`,
  `binaryUpload`, `blurb`, `longDescription`) to improve how the navigator renders them.
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
npm run gen      # ng-openapi-gen: reads openapi.json at the repo root, writes src/app/api
```

`openapi.json` and `src/app/api` are git-ignored, so neither is in a fresh clone. `npm run build`
runs `gen` first only when a non-empty `openapi.json` exists.

To replace a stub spec with a real one, run a dev-profile instance of the service and capture it:
`npm run gen:fetch:<service>`, where `<service>` is `admin`, `mod`, `user`, `federation`,
`actions` or `wiki`.

## Deploy

The Dockerfile builds a `node:24-alpine` build stage and serves the compiled bundle via
`nginx:1.27-alpine`, with CORS enabled so a host shell can fetch `remoteEntry.json` cross-origin,
and a `/healthz` endpoint for readiness probes. The build passes `--base-href=/api-docs/`: the
gateway routes `/api-docs/**` to this image, and without the flag the bundle requests its chunks
from `/`. The host shell mounts the remote at `/admin/docs`.

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
repo does not have. Both pen-test jobs also declare `needs: []`: stage ordering would otherwise run them only after
`build` succeeded, so a failed image build on the default branch would remove the security scan
from the pipeline without saying so — and `build:image` declares it too, so the `lint` stage this
file adds in front of it cannot swallow the release job the same way. Both pen-test jobs **inherit**
the base's `rules:` rather than restating them, because `extends:` *replaces* arrays: a restated copy
that dropped `.pentest-sca`'s third rule would silently delete SCA from every scheduled pipeline.
`lint:ci-wiring` asserts all of that on every push, and mutation-tests itself so a green tick means
the assertions can actually fail:

```sh
npm run check:ci-wiring   # assert this repo's pen-test wiring is not inert
npm run test:ci-wiring    # ...and prove the guard detects each way of breaking it
```

### What `pentest:dast` actually covers

Worth reading before treating a green `pentest:dast` as a statement about your merge request.
The shared harness stands up the generator's env-test-build (`make stack-up`) and points ZAP at the
gateway front door (`https://branda.localtest.me:8443` unless `DAST_TARGET` overrides it). That front door **does** reach this service — the stack builds a
`hugmesh-api-docs` container and the gateway routes `Path=/api-docs/**` to it — which is why
`DAST_TARGET` (the harness's per-repo target override) is deliberately left unset here.

What it does **not** cover is this pipeline's commit. `stack-up` populates its sources by cloning
`github.com/hugmesh/*` at `main`, and builds the api-docs image from that clone — so the scan
reports on `main`, not on `$CI_COMMIT_SHA`. On the default branch that is this commit once merged;
on a merge request it is not. Read the job as a **posture scan of the deployed platform**, never as
a per-diff gate. Narrowing it to a per-repo source needs a source-override seam in the shared
harness, which the generator owns.

Two runtime prerequisites live outside this repo and both fail as a shrug (the stage is
`allow_failure`), so the first pipeline has to be watched rather than assumed: `hugmesh-generator`
must allowlist this project for `CI_JOB_TOKEN` cross-project access or the harness clone 403s, and
the runner needs a GitHub credential or `stack-clone` cannot fetch the private sibling repos. The
harness also tears its stack down with `docker compose down -v` on the fixed project name
`hugmesh-local`, so the pen-test runner must not share a Docker daemon with a local stack anyone
cares about.

## Roadmap

- Grow the set of committed example specs as backend services publish real OpenAPI captures.

## License

MIT — see [LICENSE](LICENSE).
