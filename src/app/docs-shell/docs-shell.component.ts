/**
 * DocsShellComponent — top-level navigator for the api-docs remote.
 *
 * Layout: a service picker + tag-grouped operation sidebar on the left, a
 * per-operation detail pane on the right with two tabs (Reference /
 * Try it out). The user picks which platform service's spec to browse from the
 * SERVICE PICKER, then an operation from the sidebar; the pane shows the
 * read-only reference AND an interactive try-it-out form (with an SSE terminal
 * for streaming operations).
 *
 * Mounted at /admin/docs in the hugmesh.systems host (adminGuard). Standalone
 * — no Angular module required. Consumed by federation as './DocsShell' (and as
 * the path-'' component of API_DOCS_ROUTES via './routes').
 *
 * Spec loading mirrors the games api-docs pattern: GET the build-time-committed
 * artifact (SPECS[id].primary) → on error fall back to the live /v3/api-docs
 * (SPECS[id].fallback) → on second error surface a remediation message.
 *
 * Adapted from hugmesh.games/frontend/projects/api-docs to the hugmesh UI
 * standard: separate .ts/.html/.scss/.spec.ts, brand --hug-* tokens, full a11y
 * (service-picker label, navigation landmark, aria-current, tablist/tab/
 * tabpanel + arrow-key nav, role=alert errors).
 */
import {
  ChangeDetectionStrategy,
  Component,
  computed,
  inject,
  signal,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { ApiExplorerComponent } from '../api-explorer/api-explorer.component';
import { ApiReferenceComponent } from '../api-reference/api-reference.component';
import { screenReaderName } from '../a11y';
import { SPECS, SPEC_IDS, SpecId } from './specs';

/**
 * A flattened representation of one HTTP operation from a loaded OpenAPI spec,
 * used as the unit of selection in the sidebar and detail pane.
 */
export interface OpenApiOperation {
  /** First tag name declared on the operation, used for sidebar grouping. */
  tag: string;
  /** HTTP method in lowercase, e.g. `"get"`, `"post"`. */
  method: string;
  /** URL path template, e.g. `"/bff/admin/users/{id}"`. */
  path: string;
  /**
   * The raw OpenAPI path-item operation object (summary, parameters,
   * requestBody, responses, `x-hugmesh` extensions, etc). Intentionally
   * `any`: `ApiExplorerComponent` and `ApiReferenceComponent` each declare
   * their own narrow, purpose-specific interfaces for the specific slices of
   * this object they read (e.g. `OpenApiParameter` in both; `OpenApiSchema`,
   * `OpenApiRequestBody` and `OpenApiHugMeshExtension` in
   * `ApiReferenceComponent` only), rather than this shared type trying to
   * model the full OpenAPI operation schema.
   */
  op: any;
}

/**
 * Typed subset of the OpenAPI 3.x specification object used by the navigator.
 * Only the fields actually read by `DocsShellComponent` and its child
 * components are declared here; `paths`' operation values and `components`
 * are left as `any`/loosely-typed for the same reason as `OpenApiOperation.op`
 * above — see that doc comment.
 */
export interface OpenApiSpec {
  openapi?: string;
  info?: { title?: string; version?: string; description?: string };
  tags?: { name: string; description?: string; 'x-hugmesh'?: any }[];
  paths?: Record<string, Record<string, any>>;
  components?: any;
  /** Present on a committed STUB spec; signals "no real contract yet". */
  'x-stub'?: string;
}

/**
 * A committed spec is only USABLE if it actually carries operations. A green
 * 200-OK on a stub artifact (`x-stub` marker, or zero `paths`) must NOT be
 * treated as a real contract — otherwise the navigator renders an empty
 * operation list and the live fallback never gets a chance to fire.
 */
function specHasOperations(spec: OpenApiSpec | null | undefined): boolean {
  if (!spec || spec['x-stub']) return false;
  const paths = spec.paths;
  return !!paths && Object.keys(paths).length > 0;
}

type Tab = 'reference' | 'explore';

@Component({
  selector: 'hug-api-docs-docs-shell',
  standalone: true,
  imports: [CommonModule, ApiExplorerComponent, ApiReferenceComponent],
  changeDetection: ChangeDetectionStrategy.OnPush,
  templateUrl: './docs-shell.component.html',
  styleUrl: './docs-shell.component.scss',
})
export class DocsShellComponent {
  private readonly http = inject(HttpClient);

  /** Ordered list of known spec IDs, used to populate the service picker. */
  readonly specIds = SPEC_IDS;

  /** Registry of spec configurations keyed by {@link SpecId}. */
  readonly specs = SPECS;

  /** The fully-parsed OpenAPI spec currently loaded, or `null` while loading. */
  readonly spec = signal<OpenApiSpec | null>(null);

  /** The service whose spec is currently shown in the picker; defaults to `'admin'`. */
  readonly specId = signal<SpecId>('admin');

  /**
   * Human-readable label describing where the spec was loaded from, e.g.
   * `"Admin BFF · committed spec"` or `"Admin BFF · live /bff/admin/v3/api-docs"`.
   * Displayed as a subtitle to tell developers which source was actually used.
   */
  readonly specSource = signal<string>('loading…');

  /** Non-null when both the primary and fallback spec URLs failed to load. */
  readonly loadError = signal<string | null>(null);

  /** The operation row currently selected in the sidebar; `null` when nothing is selected. */
  readonly active = signal<OpenApiOperation | null>(null);

  /** Which detail-pane tab is shown: `'reference'` (read-only) or `'explore'` (try it out). */
  readonly tab = signal<Tab>('reference');

  /** Tabs in display order — used for the arrow-key roving tabindex (WCAG tablist pattern). */
  readonly tabs: readonly Tab[] = ['reference', 'explore'];

  constructor() {
    // Kick off spec loading immediately so the sidebar populates on first render.
    this.loadSpec();
  }

  /**
   * Switches the service picker to `id` and reloads the corresponding spec.
   * Ignores unknown IDs to guard against malformed service-picker values.
   *
   * @param id - A key from the `SPECS` registry (e.g. `'admin'`, `'mod'`).
   */
  switchSpec(id: string): void {
    if (!(id in SPECS)) return;
    this.specId.set(id as SpecId);
    this.spec.set(null);
    this.active.set(null);
    this.loadError.set(null);
    this.specSource.set('loading…');
    this.loadSpec();
  }

  /**
   * Derived list of all operations in the loaded spec, flattened from the
   * nested `paths → method` structure into `OpenApiOperation` rows.
   *
   * Only standard HTTP verbs (`get`, `post`, `put`, `delete`, `patch`) are
   * included; spec-level metadata keys (`parameters`, `servers`, etc.) are
   * silently skipped. Operations are sorted by tag → path → method so the
   * sidebar renders deterministically.
   */
  readonly operations = computed<OpenApiOperation[]>(() => {
    const s = this.spec();
    if (!s?.paths) return [];
    const rows: OpenApiOperation[] = [];
    for (const [path, ops] of Object.entries(s.paths)) {
      for (const [method, op] of Object.entries(ops || {})) {
        // Skip non-operation keys such as 'parameters' or 'servers'.
        if (!['get', 'post', 'put', 'delete', 'patch'].includes(method)) continue;
        const tag = op?.tags?.[0] || 'Untagged';
        rows.push({ tag, method, path, op });
      }
    }
    // Sort: primary by tag (for sidebar grouping), then by path, then method.
    rows.sort(
      (a, b) =>
        a.tag.localeCompare(b.tag) ||
        a.path.localeCompare(b.path) ||
        a.method.localeCompare(b.method),
    );
    return rows;
  });

  /**
   * Derived list of unique tags present in the loaded spec's operations,
   * ordered by the tag declaration order in `spec.tags` (falling back to
   * alphabetical for any tags not explicitly declared there).
   */
  readonly tags = computed(() => {
    const seen = new Map<string, { name: string }>();
    for (const op of this.operations()) {
      if (!seen.has(op.tag)) seen.set(op.tag, { name: op.tag });
    }
    // Honour the spec's tag declaration order if present.
    const declared = this.spec()?.tags || [];
    const declaredOrder = new Map(declared.map((t, i) => [t.name, i]));
    return [...seen.values()].sort(
      (a, b) =>
        (declaredOrder.get(a.name) ?? 999) - (declaredOrder.get(b.name) ?? 999) ||
        a.name.localeCompare(b.name),
    );
  });

  /**
   * Returns all operations belonging to `tag`, in the order established by the
   * `operations` computed signal (path then method).
   *
   * @param tag - The tag name to filter by.
   */
  opsByTag(tag: string): OpenApiOperation[] {
    return this.operations().filter((o) => o.tag === tag);
  }

  /**
   * Sets `op` as the currently selected operation, which causes both the
   * Reference and Try-it-out panes to refresh.
   *
   * @param op - The operation row selected by the user in the sidebar.
   */
  select(op: OpenApiOperation): void {
    this.active.set(op);
  }

  /**
   * The accessible name announced for a sidebar operation button, e.g.
   * "GET /bff/admin/things". Routed through screenReaderName so a path that
   * happens to carry a non-ASCII glyph still announces as clean ASCII while the
   * visible method badge + path keep their original text.
   */
  opLabel(op: OpenApiOperation): string {
    return screenReaderName(`${op.method.toUpperCase()} ${op.path}`);
  }

  /**
   * Returns `true` when `op` matches the currently selected operation by HTTP
   * method and path. Used by the sidebar to set `aria-current="true"` and the
   * active CSS class on the selected button.
   *
   * @param op - The sidebar button's operation row to test.
   */
  isActive(op: OpenApiOperation): boolean {
    const a = this.active();
    return !!a && a.method === op.method && a.path === op.path;
  }

  /** Arrow-key roving navigation across the two tabs (WCAG tablist pattern). */
  onTabKey(event: KeyboardEvent, current: Tab): void {
    const i = this.tabs.indexOf(current);
    let next: number | null = null;
    if (event.key === 'ArrowRight' || event.key === 'ArrowDown') next = (i + 1) % this.tabs.length;
    else if (event.key === 'ArrowLeft' || event.key === 'ArrowUp') next = (i - 1 + this.tabs.length) % this.tabs.length;
    else if (event.key === 'Home') next = 0;
    else if (event.key === 'End') next = this.tabs.length - 1;
    if (next === null) return;
    event.preventDefault();
    const target = this.tabs[next];
    this.tab.set(target);
    queueMicrotask(() => {
      document.getElementById(`tab-${target}`)?.focus();
    });
  }

  /**
   * Spec load strategy: committed primary → live fallback → honest empty-state.
   *
   * The committed primary is only accepted if it carries real operations. A
   * green 200-OK on a STUB artifact (the shipped `x-stub` / zero-`paths` spec)
   * is treated as "no usable contract" so the loader STILL falls through to the
   * live `/v3/api-docs`, instead of pinning an empty navigator. (Previously the
   * fallback only fired on an HTTP error, so a stub silently showed zero
   * operations forever.)
   */
  private loadSpec(): void {
    const id = this.specId();
    const cfg = SPECS[id];
    // Attempt 1: load the build-time committed spec artifact.
    this.http.get<OpenApiSpec>(cfg.primary).subscribe({
      next: (s) => {
        if (specHasOperations(s)) {
          this.spec.set(s);
          this.specSource.set(`${cfg.label} · committed spec`);
        } else {
          // 200-OK but a stub / 0-path spec — not a real contract; go live.
          this.loadFromFallback(id, cfg, 'committed spec is a stub');
        }
      },
      error: () => this.loadFromFallback(id, cfg, 'committed spec unavailable'),
    });
  }

  /**
   * Fetch the live `/v3/api-docs` after the committed primary was missing or a
   * stub. If the live spec also has no operations (e.g. the service is up but
   * the contract is genuinely empty), surface an honest empty-state rather than
   * a blank navigator. A network error becomes the remediation message.
   */
  private loadFromFallback(
    id: SpecId,
    cfg: { label: string; primary: string; fallback: string },
    reason: string,
  ): void {
    this.specSource.set(`${cfg.label} · ${reason}, fetching live ${cfg.fallback}`);
    this.http.get<OpenApiSpec>(cfg.fallback).subscribe({
      next: (s) => {
        if (specHasOperations(s)) {
          this.spec.set(s);
          this.specSource.set(`${cfg.label} · live ${cfg.fallback}`);
        } else {
          this.spec.set(s);
          this.loadError.set(
            `The ${cfg.label} OpenAPI spec is not yet published: the committed ` +
              `artifact at ${cfg.primary} is a stub and the live ${cfg.fallback} ` +
              `returned no operations. Commit a real spec via ` +
              `\`npm run gen:fetch:${id}\` against a dev-profile instance, or ` +
              `bring the service up so its /v3/api-docs publishes a contract.`,
          );
        }
      },
      error: (err) => {
        this.loadError.set(
          `Could not load the ${cfg.label} OpenAPI spec from ${cfg.primary} ` +
            `or ${cfg.fallback}: ${err?.message || err}. Commit a spec via ` +
            `\`npm run gen:fetch:${id}\` against a dev-profile instance, or ` +
            `bring the service up so the live /v3/api-docs is reachable.`,
        );
      },
    });
  }
}
