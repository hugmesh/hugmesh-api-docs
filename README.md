# hugmesh-api-docs

An API documentation browser for [HugMesh](https://github.com/hugmesh), open to admins only. It is
an Angular native-federation remote with its own OpenAPI navigator. It is not a generic Swagger UI.

## Highlights

- **Service picker.** Pick the backend service whose OpenAPI spec you want to read: Admin BFF, Mod
  BFF, User BFF, Federation API, HugMesh Actions, Wiki BFF.
- **Two views per spec.** The read-only **Reference** tab shows endpoints, parameters and
  request/response samples. The **Try it out** tab sends live requests. It has a JSON/multipart
  body editor and a terminal-styled viewer for streaming/SSE endpoints.
- **Spec loading that fails in the open.** The committed spec loads first. If that is missing, the
  navigator fetches the spec live from the running service. If neither works, the page says "not
  yet published". It never shows a silently empty page. A committed spec with no operations counts
  as missing. All six committed specs (`src/assets/specs/`) are stubs today, so the live fetch does
  the work.
- **Spec extensions.** Services can add `x-hugmesh` keys to their OpenAPI documents (`sampleRequest`,
  `sampleResponse`, `sampleEvent`, `sse`, `binaryUpload`, `blurb`, `longDescription`). The navigator
  uses them to render better.
- **Session auth.** Live requests carry the platform's httpOnly `bff_` session cookie. The gateway
  swaps it for the upstream bearer token server-side, so the browser never holds a token. A manual
  bearer override lets you probe another environment.
- **No backend.** A pure frontend viewer: no database, no identity-provider client, no tenant
  logic. The services it browses decide who may make the live calls.

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

`openapi.json` and `src/app/api` are git-ignored, so a fresh clone has neither. `npm run build`
runs `gen` first only when a non-empty `openapi.json` exists.

To replace a stub spec with a real one, run a dev-profile instance of the service and capture it:
`npm run gen:fetch:<service>`, where `<service>` is `admin`, `mod`, `user`, `federation`,
`actions` or `wiki`.

## Deploy

The Dockerfile builds in a `node:24-alpine` stage and serves the bundle from `nginx:1.27-alpine`.
CORS is on, so a host shell can fetch `remoteEntry.json` cross-origin. `/healthz` answers
readiness probes. The build passes `--base-href=/api-docs/`: the gateway routes `/api-docs/**` to
this image, and without the flag the bundle requests its chunks from `/`. The host shell mounts the
remote at `/admin/docs`.

## Security scanning

The pipeline carries the platform's standard OWASP pen-test stage. It comes from the generator
(`tests/pentest/ci/pentest-stage.gitlab-ci.yml`), so every onboarded repo shares one source of
truth.

| job | what it does |
| --- | --- |
| `pentest:sca` | OWASP Dependency-Check over this repo's own manifests, `--failOnCVSS 7`, SARIF into the MR security widget. |
| `pentest:dast` | Authenticated ZAP baseline + custom probes + the committed nuclei boundary templates, via the shared harness. |

Both jobs are `allow_failure: true` **by design**. A finding must never turn an onboarded repo's
pipeline red. Findings land in the archived `out/pentest` scorecard and SARIF for triage. An
*absent* scan is a different matter, and this repo is wired to prevent it:

- The harness runs from the including repo's checkout, and this repo has no `tests/pentest/`. So
  `pentest:dast` **fetches** the harness from the generator at CI time: a depth-1 clone of the same
  `main` the `include:` pins.
- Both pen-test jobs declare `needs: []`. Without it, stage order would run them only after
  `build` succeeded, and a failed image build on the default branch would drop the security scan
  without a word. `build:image` declares it too, so the `lint` stage this file adds in front of it
  cannot swallow the release job the same way.
- Both pen-test jobs **inherit** the base's `rules:`. `extends:` *replaces* arrays, so a restated
  copy that dropped `.pentest-sca`'s third rule would silently delete SCA from every scheduled
  pipeline.

`lint:ci-wiring` asserts all of that on every push. It also mutation-tests itself, so a green tick
means the assertions can fail:

```sh
npm run check:ci-wiring   # assert this repo's pen-test wiring is not inert
npm run test:ci-wiring    # ...and prove the guard detects each way of breaking it
```

### What `pentest:dast` actually covers

Read this before you treat a green `pentest:dast` as a statement about your merge request.

The shared harness stands up the generator's env-test-build (`make stack-up`) and points ZAP at the
gateway front door (`https://branda.localtest.me:8443` unless `DAST_TARGET` overrides it). That
front door **does** reach this service: the stack builds a `hugmesh-api-docs` container, and the
gateway routes `Path=/api-docs/**` to it. This is why `DAST_TARGET` (the harness's per-repo target
override) is left unset here.

It does **not** cover this pipeline's commit. `stack-up` fills its sources by cloning
`github.com/hugmesh/*` at `main` and builds the api-docs image from that clone. The scan therefore
reports on `main`, not on `$CI_COMMIT_SHA`. On the default branch that is this commit once merged.
On a merge request it is not. Treat the job as a **posture scan of the deployed platform**, never as
a per-diff gate. A per-repo source needs a source-override seam in the shared harness, and the
generator owns the harness.

Two prerequisites live outside this repo. Both fail quietly, because the stage is `allow_failure`,
so watch the first pipeline instead of assuming it works:

- `hugmesh-generator` must allowlist this project for `CI_JOB_TOKEN` cross-project access, or the
  harness clone gets a 403.
- The runner needs a GitHub credential, or `stack-clone` cannot fetch the private sibling repos.

The harness also tears its stack down with `docker compose down -v` on the fixed project name
`hugmesh-local`. Do not run the pen-test runner on a Docker daemon shared with a local stack you
care about.

## Roadmap

- Replace the six stub specs with real captures as backend services publish real OpenAPI documents.

## License

MIT — see [LICENSE](LICENSE).
