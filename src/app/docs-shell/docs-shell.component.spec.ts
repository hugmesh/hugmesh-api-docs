import { ComponentFixture, TestBed } from '@angular/core/testing';
import {
  HttpTestingController,
  provideHttpClientTesting,
} from '@angular/common/http/testing';
import { provideHttpClient } from '@angular/common/http';
import { DocsShellComponent, OpenApiSpec } from './docs-shell.component';
import { SPECS } from './specs';

/**
 * DocsShellComponent is the navigator + SERVICE PICKER. These specs pin the
 * spec-load contract (committed primary → live fallback → remediation error),
 * the picker re-load, tag grouping/sort, and the a11y surface.
 */
describe('DocsShellComponent', () => {
  let fixture: ComponentFixture<DocsShellComponent>;
  let component: DocsShellComponent;
  let httpMock: HttpTestingController;

  const sampleSpec: OpenApiSpec = {
    openapi: '3.0.1',
    info: { title: 'hugmesh-admin-bff-api', version: '0.1.0' },
    tags: [{ name: 'Beta' }, { name: 'Alpha' }],
    paths: {
      '/bff/admin/things': {
        get: { tags: ['Alpha'], summary: 'list things' },
        post: { tags: ['Alpha'], summary: 'create thing' },
      },
      '/bff/admin/widgets': {
        get: { tags: ['Beta'], summary: 'list widgets' },
      },
    },
  };

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [DocsShellComponent],
      providers: [provideHttpClient(), provideHttpClientTesting()],
    }).compileComponents();
    fixture = TestBed.createComponent(DocsShellComponent);
    component = fixture.componentInstance;
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => httpMock.verify());

  it('creates and loads the default (admin) committed spec on init', () => {
    fixture.detectChanges();
    const req = httpMock.expectOne(SPECS.admin.primary);
    expect(req.request.method).toBe('GET');
    req.flush(sampleSpec);
    expect(component.spec()?.info?.title).toBe('hugmesh-admin-bff-api');
    expect(component.specSource()).toContain('committed spec');
  });

  it('falls back to the live /v3/api-docs when the committed spec errors', () => {
    fixture.detectChanges();
    httpMock.expectOne(SPECS.admin.primary).error(new ProgressEvent('404'));
    const fb = httpMock.expectOne(SPECS.admin.fallback);
    fb.flush(sampleSpec);
    expect(component.spec()?.info?.title).toBe('hugmesh-admin-bff-api');
    expect(component.specSource()).toContain('live');
    expect(component.specSource()).toContain(SPECS.admin.fallback);
  });

  it('falls through to the live spec when the committed spec is an x-stub (200 OK, 0 paths)', () => {
    fixture.detectChanges();
    // A green 200 on the shipped STUB must NOT pin an empty navigator.
    httpMock.expectOne(SPECS.admin.primary).flush({
      'x-stub': 'STUB spec — replace via gen:fetch:admin',
      info: { title: 'hugmesh-admin-bff-api', version: '0.0.1' },
      paths: {},
    });
    httpMock.expectOne(SPECS.admin.fallback).flush(sampleSpec);
    expect(component.spec()?.info?.title).toBe('hugmesh-admin-bff-api');
    expect(component.operations().length).toBeGreaterThan(0);
    expect(component.specSource()).toContain('live');
  });

  it('falls through to the live spec when the committed spec has empty paths but no x-stub', () => {
    fixture.detectChanges();
    httpMock.expectOne(SPECS.admin.primary).flush({
      info: { title: 'hugmesh-admin-bff-api', version: '0.0.1' },
      paths: {},
    });
    httpMock.expectOne(SPECS.admin.fallback).flush(sampleSpec);
    expect(component.operations().length).toBeGreaterThan(0);
    expect(component.specSource()).toContain('live');
  });

  it('surfaces an honest "not yet published" empty-state when BOTH committed and live are stubs', () => {
    fixture.detectChanges();
    httpMock.expectOne(SPECS.admin.primary).flush({
      'x-stub': 'stub',
      info: { title: 'hugmesh-admin-bff-api', version: '0.0.1' },
      paths: {},
    });
    httpMock.expectOne(SPECS.admin.fallback).flush({
      info: { title: 'hugmesh-admin-bff-api', version: '0.0.1' },
      paths: {},
    });
    expect(component.operations().length).toBe(0);
    expect(component.loadError()).toContain('not yet published');
    expect(component.loadError()).toContain('gen:fetch:admin');
  });

  it('surfaces a remediation error when both primary and fallback fail', () => {
    fixture.detectChanges();
    httpMock.expectOne(SPECS.admin.primary).error(new ProgressEvent('404'));
    httpMock.expectOne(SPECS.admin.fallback).error(new ProgressEvent('500'));
    expect(component.loadError()).toContain('gen:fetch:admin');
    expect(component.loadError()).toContain(SPECS.admin.fallback);
  });

  it('switchSpec re-keys to another platform service and re-loads', () => {
    fixture.detectChanges();
    httpMock.expectOne(SPECS.admin.primary).flush(sampleSpec);

    component.switchSpec('federation');
    fixture.detectChanges();
    expect(component.specId()).toBe('federation');
    expect(component.spec()).toBeNull();
    const req = httpMock.expectOne(SPECS.federation.primary);
    req.flush({
      info: { title: 'hugmesh-federation-api', version: '0.1.0' },
      paths: { '/api/federation/peers': { get: { tags: ['Peers'] } } },
    });
    expect(component.spec()?.info?.title).toBe('hugmesh-federation-api');
  });

  it('ignores an unknown spec id in switchSpec', () => {
    fixture.detectChanges();
    httpMock.expectOne(SPECS.admin.primary).flush(sampleSpec);
    component.switchSpec('does-not-exist');
    expect(component.specId()).toBe('admin');
    // No second request issued.
  });

  it('groups operations by tag honouring the spec tag declaration order', () => {
    fixture.detectChanges();
    httpMock.expectOne(SPECS.admin.primary).flush(sampleSpec);
    // Declared order is [Beta, Alpha] so Beta sorts first despite alpha name.
    const tagNames = component.tags().map((t) => t.name);
    expect(tagNames).toEqual(['Beta', 'Alpha']);
    expect(component.opsByTag('Alpha').length).toBe(2);
    expect(component.opsByTag('Beta').length).toBe(1);
  });

  it('isActive reflects the selected operation', () => {
    fixture.detectChanges();
    httpMock.expectOne(SPECS.admin.primary).flush(sampleSpec);
    const op = component.operations()[0];
    expect(component.isActive(op)).toBeFalse();
    component.select(op);
    expect(component.isActive(op)).toBeTrue();
  });

  describe('accessibility', () => {
    beforeEach(() => {
      fixture.detectChanges();
      httpMock.expectOne(SPECS.admin.primary).flush(sampleSpec);
      fixture.detectChanges();
    });

    it('associates the service picker <select> with a <label for>', () => {
      const el: HTMLElement = fixture.nativeElement;
      expect(el.querySelector('#spec-picker')).not.toBeNull();
      expect(el.querySelector('label[for="spec-picker"]')).not.toBeNull();
    });

    it('wires the service picker to a visible help hint via aria-describedby', () => {
      const el: HTMLElement = fixture.nativeElement;
      const select = el.querySelector<HTMLSelectElement>('#spec-picker')!;
      const describedby = select.getAttribute('aria-describedby')!;
      expect(describedby).toBe('spec-picker-hint');
      const hint = el.querySelector(`#${describedby}`)!;
      expect(hint).withContext('describedby target exists').not.toBeNull();
      expect(hint.textContent!.trim().length).toBeGreaterThan(0);
    });

    it('describes each operation button with the navigator help hint', () => {
      const el: HTMLElement = fixture.nativeElement;
      const op = el.querySelector<HTMLButtonElement>('button.op')!;
      const describedby = op.getAttribute('aria-describedby')!;
      expect(describedby).toBe('op-list-hint');
      const hint = el.querySelector(`#${describedby}`)!;
      expect(hint).withContext('op-list-hint target exists').not.toBeNull();
      expect(hint.textContent).toContain('Select one');
    });

    it('builds an accessible name for each operation button via opLabel', () => {
      const op = component.operations()[0];
      const name = component.opLabel(op);
      expect(name).toContain(op.method.toUpperCase());
      expect(name).toContain(op.path);
      const el: HTMLElement = fixture.nativeElement;
      const first = el.querySelector<HTMLButtonElement>('button.op')!;
      expect(first.getAttribute('aria-label')!.length).toBeGreaterThan(0);
    });

    it('describes the tablist + each tab with help, and announces the selection live', () => {
      const el: HTMLElement = fixture.nativeElement;
      const tablist = el.querySelector('[role="tablist"]')!;
      expect(tablist.getAttribute('aria-describedby')).toBe('tabs-hint');
      expect(el.querySelector('#tabs-hint')).not.toBeNull();
      for (const t of ['reference', 'explore']) {
        const tab = el.querySelector(`#tab-${t}`)!;
        const db = tab.getAttribute('aria-describedby')!;
        expect(db).toBe(`tab-hint-${t}`);
        expect(el.querySelector(`#${db}`)!.textContent!.trim().length).toBeGreaterThan(0);
      }
      const live = el.querySelector('[role="status"][aria-live="polite"]')!;
      expect(live).withContext('selection live region exists').not.toBeNull();
    });

    it('renders the picker with one option per platform service', () => {
      const el: HTMLElement = fixture.nativeElement;
      const opts = el.querySelectorAll('#spec-picker option');
      expect(opts.length).toBe(Object.keys(SPECS).length);
    });

    it('uses a navigation landmark and a tablist with role=tab', () => {
      const el: HTMLElement = fixture.nativeElement;
      expect(el.querySelector('nav[aria-labelledby="nav-heading"]')).not.toBeNull();
      expect(el.querySelector('[role="tablist"]')).not.toBeNull();
      expect(el.querySelectorAll('[role="tab"]').length).toBe(2);
      expect(el.querySelector('[role="tabpanel"]')).not.toBeNull();
    });

    it('marks the selected operation button with aria-current and an aria-label', () => {
      const op = component.operations()[0];
      component.select(op);
      fixture.detectChanges();
      const el: HTMLElement = fixture.nativeElement;
      const active = el.querySelector<HTMLButtonElement>('button.op.active')!;
      expect(active.getAttribute('aria-current')).toBe('true');
      expect(active.getAttribute('aria-label')).toContain(op.method.toUpperCase());
      expect(active.getAttribute('aria-label')).toContain(op.path);
    });

    it('moves the active tab with ArrowRight (roving tablist)', () => {
      expect(component.tab()).toBe('reference');
      component.onTabKey(
        new KeyboardEvent('keydown', { key: 'ArrowRight' }),
        'reference',
      );
      expect(component.tab()).toBe('explore');
      component.onTabKey(
        new KeyboardEvent('keydown', { key: 'ArrowLeft' }),
        'explore',
      );
      expect(component.tab()).toBe('reference');
    });

    it('wraps the roving tablist and supports Home/End (full APG)', () => {
      // ArrowLeft from the first tab wraps to the last.
      component.onTabKey(
        new KeyboardEvent('keydown', { key: 'ArrowLeft' }),
        'reference',
      );
      expect(component.tab()).toBe('explore');
      // ArrowRight from the last tab wraps to the first.
      component.onTabKey(
        new KeyboardEvent('keydown', { key: 'ArrowRight' }),
        'explore',
      );
      expect(component.tab()).toBe('reference');
      // End jumps to the last tab, Home back to the first.
      component.onTabKey(new KeyboardEvent('keydown', { key: 'End' }), 'reference');
      expect(component.tab()).toBe('explore');
      component.onTabKey(new KeyboardEvent('keydown', { key: 'Home' }), 'explore');
      expect(component.tab()).toBe('reference');
    });

    it('ignores non-navigation keys without preventing default (typing passes through)', () => {
      const ev = new KeyboardEvent('keydown', { key: 'a' });
      const prevent = spyOn(ev, 'preventDefault');
      component.onTabKey(ev, 'reference');
      expect(component.tab()).toBe('reference');
      expect(prevent).not.toHaveBeenCalled();
    });

    it('roving tab nav preventsDefault + moves DOM focus to the newly-selected tab', async () => {
      const ev = new KeyboardEvent('keydown', { key: 'ArrowRight' });
      const prevent = spyOn(ev, 'preventDefault');
      component.onTabKey(ev, 'reference');
      expect(prevent).withContext('arrow key consumed').toHaveBeenCalled();
      fixture.detectChanges();
      // onTabKey schedules focus() in a microtask — await it, then assert the
      // newly-selected tab button owns DOM focus (roving-tabindex focus move).
      await Promise.resolve();
      const el: HTMLElement = fixture.nativeElement;
      const explore = el.querySelector<HTMLButtonElement>('#tab-explore')!;
      expect(document.activeElement).withContext('focus moved to active tab').toBe(explore);
      // The selected tab is the only roving-focusable one (tabindex 0); the other is -1.
      expect(explore.getAttribute('tabindex')).toBe('0');
      expect(el.querySelector('#tab-reference')!.getAttribute('tabindex')).toBe('-1');
    });

    it('keeps native keyboard operability on the operation list (real <button>, no positive tabindex)', () => {
      const el: HTMLElement = fixture.nativeElement;
      const opButtons = el.querySelectorAll<HTMLButtonElement>('button.op');
      expect(opButtons.length).toBeGreaterThan(0);
      opButtons.forEach((b) => {
        // Native <button> is Tab-reachable + Enter/Space-activatable by the
        // browser; a positive tabindex would corrupt focus order (WCAG 2.4.3).
        expect(b.tagName).toBe('BUTTON');
        const ti = b.getAttribute('tabindex');
        expect(ti === null || Number(ti) <= 0)
          .withContext('no positive tabindex on op button')
          .toBe(true);
      });
    });

    it('activating an operation button (native Enter/Space → click) selects that operation', () => {
      const el: HTMLElement = fixture.nativeElement;
      const first = el.querySelector<HTMLButtonElement>('button.op')!;
      expect(component.active()).toBeNull();
      // The browser dispatches a click for Enter/Space on a native button; emulate
      // that activation and assert the operation becomes the active selection.
      first.click();
      fixture.detectChanges();
      expect(component.active()).not.toBeNull();
      const active = el.querySelector<HTMLButtonElement>('button.op.active')!;
      expect(active.getAttribute('aria-current')).toBe('true');
    });

    it('activating a tab via native click (Enter/Space proxy) switches the panel', () => {
      const el: HTMLElement = fixture.nativeElement;
      expect(component.tab()).toBe('reference');
      el.querySelector<HTMLButtonElement>('#tab-explore')!.click();
      fixture.detectChanges();
      expect(component.tab()).toBe('explore');
      const panel = el.querySelector('[role="tabpanel"]')!;
      expect(panel.getAttribute('aria-labelledby')).toBe('tab-explore');
    });
  });
});
