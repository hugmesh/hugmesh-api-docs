/**
 * ApiExplorerComponent — interactive try-it-out for the selected OpenAPI spec.
 * Shown on the "Try it out" tab of DocsShellComponent.
 *
 * Features:
 *   • Session-cookie auth. Live requests ride the platform's httpOnly `bff_`
 *     session cookie (`credentials: 'include'`, the same convention as the
 *     host shell's bearer interceptor and the login-ui raw-fetch call sites);
 *     the gateway's BffCookieToBearerWebFilter exchanges it for the upstream
 *     bearer SERVER-SIDE, so the browser never holds a JWT.
 *   • Auth-token override textbox. Empty by default and purely MANUAL — for
 *     pasting a token when there is no session cookie (e.g. probing another
 *     environment). Because the gateway's cookie bridge only fires when NO
 *     `Authorization` header is present, a non-empty override deliberately
 *     SUPPRESSES the cookie exchange; leaving it blank is the normal path.
 *   • Path / query parameter form, defaulted from the spec.
 *   • Request-body editor (JSON for application/json, file picker for a
 *     multipart binary field).
 *   • Sample request preload from x-hugmesh.sampleRequest.
 *   • Fetch-based "Send" that sends the session cookie and respects the
 *     override token when one has been typed.
 *   • Live response panel: status, headers, body (JSON pretty-printed).
 *   • Terminal-styled SSE viewer for endpoints with x-hugmesh.sse (or a
 *     text/event-stream response). Opens a fetch-stream and appends incoming
 *     events; "Stop" cancels via AbortController.
 *
 * Adapted from hugmesh.games/frontend/projects/api-docs to the hugmesh UI
 * standard: separate .ts/.html/.scss/.spec.ts, brand --hug-* tokens, accessible
 * form (<label for>, aria-invalid), SSE terminal as role="log" aria-live.
 */
import {
  ChangeDetectionStrategy,
  Component,
  ElementRef,
  Input,
  OnChanges,
  ViewChild,
  signal,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { screenReaderName } from '../a11y';
import { OpenApiOperation, OpenApiSpec } from '../docs-shell/docs-shell.component';

interface ParamMap {
  [k: string]: string;
}

/** A single OpenAPI parameter object (`in: path | query | header | cookie`). */
interface OpenApiParameter {
  name: string;
  in?: string;
  required?: boolean;
  description?: string;
  schema?: { type?: string };
}

/** The `x-hugmesh.binaryUpload` extension object for multipart file fields. */
interface BinaryUpload {
  /** Name of the `multipart/form-data` field to append the selected file to. */
  field: string;
  description?: string;
  /** `accept` attribute value for the file `<input>`, e.g. `"image/*"`. */
  accept?: string;
}

@Component({
  selector: 'hug-api-docs-api-explorer',
  standalone: true,
  imports: [CommonModule, FormsModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  templateUrl: './api-explorer.component.html',
  styleUrl: './api-explorer.component.scss',
})
export class ApiExplorerComponent implements OnChanges {
  /** The full parsed OpenAPI spec object for the currently selected service. */
  @Input() spec: OpenApiSpec | null = null;

  /**
   * The operation currently displayed in the detail pane. An `OpenApiOperation`
   * containing `{ tag, method, path, op }` where `op` is the raw spec object
   * for that path+method entry.
   */
  @Input() active: OpenApiOperation | null = null;

  /** Template reference to the SSE terminal `<div role="log">` for auto-scroll. */
  @ViewChild('term') termEl?: ElementRef<HTMLElement>;

  /**
   * Manual bearer override typed into the auth textbox. Empty by default —
   * the session cookie authorises the request — and deliberately PRESERVED
   * across operation switches so a pasted token survives navigating the
   * sidebar.
   */
  token = '';
  /** Current values for each `{param}` path placeholder, keyed by parameter name. */
  pathValues: ParamMap = {};
  /** Current values for query parameters, keyed by parameter name. */
  queryValues: ParamMap = {};
  /** Raw JSON text typed into the request-body editor. */
  bodyJson = '';
  /** File selected via the binary-upload input for `multipart/form-data` endpoints. */
  selectedFile: File | null = null;

  /** `true` while a fetch request (non-SSE) is in flight. */
  readonly busy = signal<boolean>(false);

  /**
   * The most recent HTTP response, or `null` when no request has been sent yet
   * or the form was reset. The `body` string is JSON-pretty-printed for
   * `application/json` responses and left raw otherwise.
   */
  readonly response = signal<{
    status: number;
    statusText: string;
    body: string;
    /** Round-trip latency in milliseconds, measured via `performance.now()`. */
    duration: number;
  } | null>(null);

  /** Error message for a failed fetch (network error, CORS, etc.), or `null`. */
  readonly responseError = signal<string | null>(null);

  /** JSON parse error from the body editor, or `null` when the body is valid. */
  readonly bodyError = signal<string | null>(null);

  /** `true` while an SSE stream subscription is open. */
  readonly sseActive = signal<boolean>(false);

  /**
   * Accumulated text in the SSE terminal. Appended to by `appendLog` as
   * each `\n\n`-delimited SSE chunk arrives from the stream.
   */
  readonly sseLog = signal<string>('');

  /**
   * Controller used to cancel an in-flight SSE fetch when the user clicks
   * "Stop" or a new operation is selected.
   */
  private sseAbort: AbortController | null = null;

  /**
   * Resets the form and pre-fills state whenever the active operation changes.
   * If the spec carries an `x-hugmesh.sampleRequest` for this operation,
   * that object is serialised into the body editor as pretty JSON.
   *
   * `token` is intentionally NOT touched here: it is a manual override, so
   * wiping it on every sidebar click would discard what the user just pasted.
   */
  ngOnChanges(): void {
    if (!this.active) return;
    this.resetForm();
    const sample = this.active.op?.['x-hugmesh']?.sampleRequest;
    // Pre-fill the body editor with the committed sample request when available.
    if (sample && this.hasJsonBody()) {
      this.bodyJson = JSON.stringify(sample, null, 2);
    }
  }

  /**
   * Accessible name for a parameter input. The visible <label> only shows the
   * raw name + type; this expands it (and required-ness) so a screen-reader
   * user hears e.g. "id, required path parameter (string)" with the parameter
   * name announced as clean ASCII even if the spec used a non-ASCII glyph.
   */
  paramAccessibleName(p: OpenApiParameter, kind: 'path' | 'query'): string {
    const type = p?.schema?.type || 'string';
    const required = kind === 'path' || p?.required ? ', required' : '';
    return screenReaderName(`${p?.name}${required} ${kind} parameter (${type})`);
  }

  /** Path parameters (`in: path`) from the active operation's parameter list. */
  get pathParams(): OpenApiParameter[] {
    return (this.active?.op?.parameters || []).filter((p: OpenApiParameter) => p.in === 'path');
  }

  /** Query parameters (`in: query`) from the active operation's parameter list. */
  get queryParams(): OpenApiParameter[] {
    return (this.active?.op?.parameters || []).filter((p: OpenApiParameter) => p.in === 'query');
  }

  /** Returns `true` when the operation declares an `application/json` request body. */
  hasJsonBody(): boolean {
    return !!this.active?.op?.requestBody?.content?.['application/json'];
  }

  /**
   * Returns the `x-hugmesh.binaryUpload` extension object when the operation
   * expects a `multipart/form-data` binary field, or `null` otherwise. The
   * returned object's `field` property names the form field to append the file to.
   */
  binaryUpload(): BinaryUpload | null {
    return this.active?.op?.['x-hugmesh']?.binaryUpload || null;
  }

  /**
   * Returns `true` when the operation streams `text/event-stream` responses,
   * either via the `x-hugmesh.sse` extension flag or a declared
   * `text/event-stream` response content type. SSE operations are handled by
   * `startSse` rather than the regular `send` fetch.
   */
  isSse(): boolean {
    if (this.active?.op?.['x-hugmesh']?.sse) return true;
    const responses = this.active?.op?.responses || {};
    for (const r of Object.values<any>(responses)) {
      if (r?.content?.['text/event-stream']) return true;
    }
    return false;
  }

  /**
   * CSS class to apply to the response status badge: `s2xx` for success,
   * `s4xx` for client errors, `s5xx` for everything else.
   */
  statusClass(): string {
    const s = this.response()?.status || 0;
    if (s >= 200 && s < 300) return 's2xx';
    if (s >= 400 && s < 500) return 's4xx';
    return 's5xx';
  }

  /**
   * Clears all form state and response output.
   * Called on every operation switch (via `ngOnChanges`) to ensure no stale
   * path/query values, body text, file selection, or previous response bleed
   * across to a newly selected endpoint.
   */
  resetForm(): void {
    this.pathValues = {};
    this.queryValues = {};
    this.bodyJson = '';
    this.selectedFile = null;
    this.response.set(null);
    this.responseError.set(null);
    this.bodyError.set(null);
    this.sseLog.set('');
  }

  /**
   * Handles the `<input type="file">` change event and stores the selected
   * file for submission in a `multipart/form-data` body.
   *
   * @param e - The native DOM `change` event from the file input.
   */
  onFileSelected(e: Event): void {
    const f = (e.target as HTMLInputElement).files?.[0];
    this.selectedFile = f || null;
  }

  /**
   * Initiates the request for the active operation.
   * SSE operations are routed to `startSse`; all other HTTP methods are
   * dispatched via `fetch` with the session cookie, any manual bearer
   * override, and any body attached.
   */
  send(): void {
    if (this.isSse()) {
      this.startSse();
      return;
    }
    this.responseError.set(null);
    this.bodyError.set(null);
    this.response.set(null);

    const url = this.buildUrl();
    // `send` is only invoked from the template once an operation is selected,
    // so `active` is guaranteed non-null here.
    const init: RequestInit = {
      method: this.active!.method.toUpperCase(),
      headers: this.buildHeaders(),
      // Ride the platform session: the httpOnly `bff_` cookie is what
      // authorises the ROLE_ADMIN-gated endpoints. Explicit rather than
      // relying on fetch's `same-origin` default, so the call still carries
      // the session if the explorer is ever pointed at a cross-origin gateway.
      credentials: 'include',
    };
    const upload = this.binaryUpload();
    if (upload && this.selectedFile) {
      const fd = new FormData();
      fd.append(upload.field, this.selectedFile);
      init.body = fd;
    } else if (this.hasJsonBody() && this.bodyJson.trim()) {
      try {
        init.body = JSON.stringify(JSON.parse(this.bodyJson));
        (init.headers as Record<string, string>)['Content-Type'] = 'application/json';
      } catch (e: any) {
        this.bodyError.set('Body is not valid JSON: ' + (e?.message || e));
        return;
      }
    }

    this.busy.set(true);
    const t0 = performance.now();
    fetch(url, init)
      .then(async (r) => {
        const text = await r.text();
        let body = text;
        const ct = r.headers.get('content-type') || '';
        if (ct.includes('application/json')) {
          try {
            body = JSON.stringify(JSON.parse(text), null, 2);
          } catch {
            /* leave raw */
          }
        }
        this.response.set({
          status: r.status,
          statusText: r.statusText,
          body,
          duration: Math.round(performance.now() - t0),
        });
      })
      .catch((e) => this.responseError.set(e?.message || String(e)))
      .finally(() => this.busy.set(false));
  }

  /**
   * Opens an SSE subscription to the active endpoint and streams incoming
   * events into the terminal log.
   *
   * Flow:
   * 1. Aborts any existing SSE connection so only one stream is open at a time.
   * 2. Sends a `fetch` with `Accept: text/event-stream`, the session cookie,
   *    and any manual bearer override.
   * 3. Reads the response body with a `ReadableStreamDefaultReader`, buffering
   *    UTF-8 text until double-newline (`\n\n`) event boundaries are found.
   * 4. Each complete SSE chunk is appended to `sseLog` via `appendLog`.
   * 5. On `AbortError` (user clicked "Stop"), the error is silenced and the
   *    terminal shows a cancellation marker. Other errors are appended as text.
   */
  private startSse(): void {
    if (this.sseAbort) this.sseAbort.abort();
    this.sseAbort = new AbortController();
    this.sseActive.set(true);
    this.sseLog.set('');
    // `startSse` is only invoked once an operation is selected, so `active` is
    // guaranteed non-null here.
    this.appendLog(`→ subscribing ${this.active!.method.toUpperCase()} ${this.buildUrl()}\n\n`);

    const url = this.buildUrl();
    fetch(url, {
      headers: { ...this.buildHeaders(), Accept: 'text/event-stream' },
      // Same session-cookie contract as `send` — see the note there.
      credentials: 'include',
      signal: this.sseAbort.signal,
    })
      .then(async (r) => {
        if (!r.ok) {
          this.appendLog(`HTTP ${r.status} ${r.statusText}\n`);
          this.sseActive.set(false);
          return;
        }
        if (!r.body) {
          this.appendLog('no response body\n');
          this.sseActive.set(false);
          return;
        }
        const reader = r.body.getReader();
        const decoder = new TextDecoder('utf-8');
        let buffer = '';
        for (;;) {
          const { value, done } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          let idx;
          while ((idx = buffer.indexOf('\n\n')) !== -1) {
            const chunk = buffer.slice(0, idx);
            buffer = buffer.slice(idx + 2);
            this.appendLog(chunk + '\n\n');
          }
        }
      })
      .catch((e) => {
        if (e?.name !== 'AbortError') this.appendLog(String(e) + '\n');
      })
      .finally(() => this.sseActive.set(false));
  }

  /**
   * Cancels the active SSE stream and appends a cancellation marker to the log.
   * Safe to call when no stream is open — `AbortController.abort` is idempotent.
   */
  stopSse(): void {
    this.sseAbort?.abort();
    this.appendLog('— subscription cancelled —\n');
  }

  /**
   * Appends `text` to the SSE terminal log and scrolls the terminal element to
   * the bottom. The scroll happens in a microtask so the DOM has had a chance
   * to update with the newly appended text before `scrollTop` is set.
   *
   * @param text - Raw text to append (may include SSE `data:` prefixes).
   */
  private appendLog(text: string): void {
    this.sseLog.update((prev) => prev + text);
    queueMicrotask(() => {
      const el = this.termEl?.nativeElement;
      if (el) el.scrollTop = el.scrollHeight;
    });
  }

  /**
   * Constructs the request URL for the active operation by substituting
   * `{param}` placeholders in the path with percent-encoded values from
   * `pathValues`, then appending any non-empty query parameters.
   *
   * @returns The fully constructed URL string (relative, e.g. `/bff/admin/users?page=0`).
   */
  buildUrl(): string {
    // `buildUrl` is only called once an operation is selected, so `active` is
    // guaranteed non-null here.
    let path = this.active!.path;
    for (const p of this.pathParams) {
      const v = this.pathValues[p.name] ?? '';
      path = path.replaceAll(`{${p.name}}`, encodeURIComponent(v));
    }
    const q: string[] = [];
    for (const qp of this.queryParams) {
      const v = this.queryValues[qp.name];
      if (v != null && v !== '') {
        q.push(`${encodeURIComponent(qp.name)}=${encodeURIComponent(v)}`);
      }
    }
    return path + (q.length ? '?' + q.join('&') : '');
  }

  /**
   * Builds the request headers object. Adds an `Authorization: Bearer` header
   * ONLY when the user has typed a manual override; otherwise the header is
   * omitted so the gateway's cookie-to-bearer bridge (which stands down as
   * soon as an `Authorization` header is present) can exchange the `bff_`
   * session cookie server-side.
   *
   * @returns A plain object of header name → value pairs.
   */
  private buildHeaders(): Record<string, string> {
    const h: Record<string, string> = {};
    if (this.token) h['Authorization'] = 'Bearer ' + this.token;
    return h;
  }
}
