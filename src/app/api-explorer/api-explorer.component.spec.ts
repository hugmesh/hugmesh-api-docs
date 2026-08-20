import { ComponentFixture, TestBed } from '@angular/core/testing';
import { ApiExplorerComponent } from './api-explorer.component';

/**
 * ApiExplorerComponent specs pin the try-it-out behaviour: session-cookie auth
 * with a manual bearer override, URL building with path/query substitution,
 * JSON-body validation, SSE detection + start/stop, and the a11y form surface.
 */
describe('ApiExplorerComponent', () => {
  let fixture: ComponentFixture<ApiExplorerComponent>;
  let component: ApiExplorerComponent;

  const op = {
    tag: 'Things',
    method: 'get',
    path: '/bff/admin/things/{id}',
    op: {
      parameters: [
        { name: 'id', in: 'path', schema: { type: 'string' } },
        { name: 'verbose', in: 'query', schema: { type: 'boolean' } },
      ],
      responses: { '200': { description: 'ok' } },
    },
  };

  beforeEach(async () => {
    localStorage.clear();
    await TestBed.configureTestingModule({
      imports: [ApiExplorerComponent],
    }).compileComponents();
    fixture = TestBed.createComponent(ApiExplorerComponent);
    component = fixture.componentInstance;
  });

  afterEach(() => localStorage.clear());

  it('creates', () => {
    fixture.detectChanges();
    expect(component).toBeTruthy();
  });

  /**
   * The browser holds ONLY the opaque httpOnly `bff_` cookie — never a JWT — so
   * there is nothing in localStorage to preload. Reading one back would be worse
   * than useless: the gateway's BffCookieToBearerWebFilter stands down as soon as
   * an `Authorization` header is present, so a stale token would SUPPRESS the
   * cookie exchange and 401 a perfectly good session.
   */
  it('leaves the override empty rather than preloading a token from localStorage', () => {
    localStorage.setItem('hug.session', JSON.stringify({ bffToken: 'admin-jwt-123' }));
    localStorage.setItem('tw_auth', JSON.stringify({ accessToken: 'legacy-tok' }));
    component.active = op;
    component.ngOnChanges();
    expect(component.token).toBe('');
  });

  it('sends the session cookie and NO Authorization header when the override is empty', async () => {
    const fetchSpy = spyOn(window, 'fetch').and.resolveTo(
      new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } }),
    );
    component.active = op;
    component.ngOnChanges();
    component.send();
    const [, init] = fetchSpy.calls.mostRecent().args as [string, RequestInit];
    expect(init.credentials).toBe('include');
    expect((init.headers as Record<string, string>)['Authorization']).toBeUndefined();
  });

  it('sends a manually pasted override as a bearer header, still with credentials', () => {
    const fetchSpy = spyOn(window, 'fetch').and.resolveTo(new Response('{}', { status: 200 }));
    component.active = op;
    component.ngOnChanges();
    component.token = 'pasted-tok';
    component.send();
    const [, init] = fetchSpy.calls.mostRecent().args as [string, RequestInit];
    expect((init.headers as Record<string, string>)['Authorization']).toBe('Bearer pasted-tok');
    expect(init.credentials).toBe('include');
  });

  /**
   * Regression: `ngOnChanges` used to overwrite `token` on every operation
   * switch, so a manually pasted override was silently wiped by a sidebar click.
   */
  it('preserves a pasted override across an operation switch', () => {
    component.active = op;
    component.ngOnChanges();
    component.token = 'pasted-tok';
    component.active = { ...op, path: '/bff/admin/other' };
    component.ngOnChanges();
    expect(component.token).toBe('pasted-tok');
  });

  it('opens the SSE stream with the session cookie', () => {
    const fetchSpy = spyOn(window, 'fetch').and.resolveTo({
      ok: true,
      body: { getReader: () => ({ read: () => new Promise(() => {}) }) },
    } as unknown as Response);
    component.active = { ...op, op: { 'x-hugmesh': { sse: true }, responses: {} } };
    component.ngOnChanges();
    component.send();
    const [, init] = fetchSpy.calls.mostRecent().args as [string, RequestInit];
    expect(init.credentials).toBe('include');
  });

  it('substitutes path params and appends non-empty query params in buildUrl', () => {
    component.active = op;
    component.ngOnChanges();
    component.pathValues['id'] = 'abc 1';
    component.queryValues['verbose'] = 'true';
    expect(component.buildUrl()).toBe('/bff/admin/things/abc%201?verbose=true');
  });

  it('omits empty query params from the URL', () => {
    component.active = op;
    component.ngOnChanges();
    component.pathValues['id'] = 'x';
    component.queryValues['verbose'] = '';
    expect(component.buildUrl()).toBe('/bff/admin/things/x');
  });

  it('rejects an invalid JSON body with a role=alert error and no fetch', () => {
    const fetchSpy = spyOn(window, 'fetch');
    const postOp = {
      ...op,
      method: 'post',
      op: {
        requestBody: { content: { 'application/json': { schema: {} } } },
        responses: {},
      },
    };
    component.active = postOp;
    component.ngOnChanges();
    component.bodyJson = '{ not json';
    component.send();
    expect(component.bodyError()).toContain('not valid JSON');
    expect(fetchSpy).not.toHaveBeenCalled();
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    const alert = el.querySelector('#body-error')!;
    expect(alert.getAttribute('role')).toBe('alert');
  });

  it('detects an SSE operation from a text/event-stream response', () => {
    component.active = {
      ...op,
      op: {
        responses: { '200': { content: { 'text/event-stream': {} } } },
      },
    };
    expect(component.isSse()).toBeTrue();
  });

  it('detects an SSE operation from the x-hugmesh.sse extension', () => {
    component.active = { ...op, op: { 'x-hugmesh': { sse: true }, responses: {} } };
    expect(component.isSse()).toBeTrue();
  });

  it('start/stop SSE toggles the active signal via AbortController', () => {
    const reader = {
      read: () => new Promise(() => {}), // never resolves — simulates an open stream
    };
    spyOn(window, 'fetch').and.resolveTo({
      ok: true,
      body: { getReader: () => reader },
    } as unknown as Response);
    component.active = { ...op, op: { 'x-hugmesh': { sse: true }, responses: {} } };
    component.ngOnChanges();
    component.send();
    expect(component.sseActive()).toBeTrue();
    component.stopSse();
    expect(component.sseLog()).toContain('cancelled');
  });

  describe('accessibility', () => {
    it('shows an empty-state prompt when no operation is selected', () => {
      fixture.detectChanges();
      const el: HTMLElement = fixture.nativeElement;
      expect(el.querySelector('.empty h2')!.textContent).toContain('Pick an operation');
    });

    it('associates the token input and every param input with a <label for>', () => {
      component.active = op;
      fixture.detectChanges();
      const el: HTMLElement = fixture.nativeElement;
      for (const id of ['tok', 'p_id', 'q_verbose']) {
        expect(el.querySelector(`#${id}`)).withContext(`#${id}`).not.toBeNull();
        expect(el.querySelector(`label[for="${id}"]`)).withContext(`label for #${id}`).not.toBeNull();
      }
    });

    it('renders the SSE terminal as a role=log aria-live region', () => {
      component.active = { ...op, op: { 'x-hugmesh': { sse: true }, responses: {} } };
      fixture.detectChanges();
      const el: HTMLElement = fixture.nativeElement;
      const term = el.querySelector('.terminal')!;
      expect(term.getAttribute('role')).toBe('log');
      expect(term.getAttribute('aria-live')).toBe('polite');
    });

    it('wires path + query inputs to a help hint whose target exists', () => {
      component.active = op;
      fixture.detectChanges();
      const el: HTMLElement = fixture.nativeElement;
      for (const [id, fallback] of [
        ['p_id', 'path-params-hint'],
        ['q_verbose', 'query-params-hint'],
      ]) {
        const input = el.querySelector<HTMLInputElement>(`#${id}`)!;
        const db = input.getAttribute('aria-describedby')!;
        expect(db).withContext(`${id} aria-describedby`).toBe(fallback);
        const hint = el.querySelector(`#${db}`)!;
        expect(hint).withContext(`${id} hint target`).not.toBeNull();
        expect(hint.textContent!.trim().length).toBeGreaterThan(0);
        // Each input also carries a non-empty accessible name.
        expect(input.getAttribute('aria-label')!.length).toBeGreaterThan(0);
      }
    });

    it('prefers a parameter description as its describedby hint when present', () => {
      const describedOp = {
        ...op,
        op: {
          parameters: [
            { name: 'id', in: 'path', description: 'The thing id.', schema: { type: 'string' } },
          ],
          responses: {},
        },
      };
      component.active = describedOp;
      fixture.detectChanges();
      const el: HTMLElement = fixture.nativeElement;
      const input = el.querySelector<HTMLInputElement>('#p_id')!;
      expect(input.getAttribute('aria-describedby')).toBe('p_id_desc');
      expect(el.querySelector('#p_id_desc')!.textContent).toContain('The thing id.');
    });

    it('paramAccessibleName announces required + kind + type', () => {
      expect(
        component.paramAccessibleName({ name: 'id', schema: { type: 'string' } }, 'path'),
      ).toBe('id, required path parameter (string)');
      expect(
        component.paramAccessibleName({ name: 'verbose', schema: { type: 'boolean' } }, 'query'),
      ).toBe('verbose query parameter (boolean)');
    });

    it('gives the JSON body textarea a label + visible help hint', () => {
      const postOp = {
        ...op,
        method: 'post',
        op: {
          requestBody: { content: { 'application/json': { schema: {} } } },
          responses: {},
        },
      };
      component.active = postOp;
      fixture.detectChanges();
      const el: HTMLElement = fixture.nativeElement;
      const ta = el.querySelector<HTMLTextAreaElement>('#bodyJson')!;
      expect(ta.getAttribute('aria-label')).toContain('Request body');
      expect(ta.getAttribute('aria-describedby')).toContain('body-hint');
      expect(el.querySelector('#body-hint')!.textContent!.trim().length).toBeGreaterThan(0);
    });

    it('gives the file input a label + describedby hint that exists', () => {
      const binOp = {
        ...op,
        method: 'post',
        op: {
          'x-hugmesh': {
            binaryUpload: { field: 'file', accept: '.png', description: 'Upload an image' },
          },
          responses: {},
        },
      };
      component.active = binOp;
      fixture.detectChanges();
      const el: HTMLElement = fixture.nativeElement;
      const bin = el.querySelector<HTMLInputElement>('#bin')!;
      expect(bin.getAttribute('aria-label')).toContain('Binary upload');
      expect(bin.getAttribute('aria-describedby')).toBe('bin-hint');
      expect(el.querySelector('#bin-hint')!.textContent).toContain('Upload an image');
    });

    it('describes the Send and Reset buttons with help hints that exist', () => {
      component.active = op;
      fixture.detectChanges();
      const el: HTMLElement = fixture.nativeElement;
      const send = el.querySelector<HTMLButtonElement>('button.primary')!;
      expect(send.getAttribute('aria-describedby')).toBe('send-hint');
      expect(send.getAttribute('aria-label')).toContain('Send');
      expect(el.querySelector('#send-hint')!.textContent!.trim().length).toBeGreaterThan(0);
      const reset = el.querySelector<HTMLButtonElement>('button.secondary')!;
      expect(reset.getAttribute('aria-describedby')).toBe('reset-hint');
      expect(el.querySelector('#reset-hint')!.textContent).toContain('Clears');
    });

    it('exposes every action as a native <button> with no positive tabindex (keyboard-reachable + Enter/Space-activatable)', () => {
      component.active = op;
      fixture.detectChanges();
      const el: HTMLElement = fixture.nativeElement;
      const buttons = el.querySelectorAll<HTMLButtonElement>('.actions button');
      expect(buttons.length).toBeGreaterThan(0);
      buttons.forEach((b) => {
        expect(b.tagName).toBe('BUTTON');
        // type=button keeps Enter/Space activation from submitting any ambient form.
        expect(b.getAttribute('type')).toBe('button');
        const ti = b.getAttribute('tabindex');
        expect(ti === null || Number(ti) <= 0).toBe(true);
      });
    });

    it('activating Reset via native click (Enter/Space proxy) clears the form', () => {
      component.active = op;
      component.ngOnChanges();
      component.pathValues['id'] = 'set';
      component.responseError.set('boom');
      fixture.detectChanges();
      const el: HTMLElement = fixture.nativeElement;
      // The browser turns Enter/Space on a native button into a click; emulate it.
      const reset = el.querySelector<HTMLButtonElement>('button.secondary')!;
      reset.click();
      expect(component.pathValues['id']).toBeUndefined();
      expect(component.responseError()).toBeNull();
    });

    it('keeps the Send button operable until busy, then disables it (no keyboard trap on a dead control)', () => {
      component.active = op;
      fixture.detectChanges();
      const el: HTMLElement = fixture.nativeElement;
      const send = el.querySelector<HTMLButtonElement>('button.primary')!;
      expect(send.disabled).toBeFalse();
      component.busy.set(true);
      fixture.detectChanges();
      // A disabled native button drops out of the Tab order rather than trapping
      // focus on an unusable control — correct per WCAG 2.1.2.
      expect(send.disabled).toBeTrue();
    });
  });
});
