import { ComponentFixture, TestBed } from '@angular/core/testing';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { provideHttpClient } from '@angular/common/http';
import { DocsShellComponent, OpenApiSpec } from './docs-shell.component';
import { SPECS } from './specs';

/**
 * Phone-width layout (GUI-30): at 390x844, /admin/docs kept the 300px navigator beside the
 * detail pane, so the pane's header wrapped one character per line ("v / 0 / . / 1") and the
 * view came out 433px wide, scrolling the whole page sideways.
 *
 * Two things have to be true for the bug to show, and both are reproduced here:
 *  - a phone-width VIEWPORT, because the fix is a media query. The karma window is far
 *    wider, so the spec narrows the karma context iframe itself (window.frameElement)
 *    and asserts the viewport really is that wide before measuring anything;
 *  - the host shell's SIZING of a routed view. The shell's `router-outlet + *` backpane
 *    has auto inline margins inside a column flexbox, so the view shrinks to fit its
 *    content and never goes below that content's min-content width. In a plain block the
 *    shell would stay inside the page and only its pane would be crushed.
 */

/** Widths checked: the reported phone (390) and the narrowest common one (320). */
const PHONE_WIDTHS = [390, 320];

/** Viewport height used throughout: the reported phone's (390x844). */
const VIEWPORT_HEIGHT = 844;

function nextFrame(): Promise<void> {
  return new Promise((resolve) => requestAnimationFrame(() => resolve()));
}

/** Resize the karma context iframe so media queries see a `width` x 844 viewport (null restores it). */
async function setViewportWidth(width: number | null): Promise<void> {
  const frame = window.frameElement as HTMLElement | null;
  if (!frame) {
    throw new Error(
      'phone-width specs resize the karma context iframe and cannot run without one ' +
        '(the karma debug page runs specs in the top window)',
    );
  }
  frame.style.width = width === null ? '' : `${width}px`;
  frame.style.height = width === null ? '' : `${VIEWPORT_HEIGHT}px`;
  await nextFrame();
  await nextFrame();
  if (width !== null) {
    expect(window.innerWidth).withContext('viewport width after resizing the karma iframe').toBe(width);
    expect(window.innerHeight).withContext('viewport height after resizing the karma iframe').toBe(VIEWPORT_HEIGHT);
    expect(window.matchMedia(`(max-width: ${width}px)`).matches).withContext('media queries see the narrow viewport').toBeTrue();
  }
}

/** Mount the component's host element the way the host shell mounts a routed view. */
function mountInShell(host: HTMLElement): HTMLElement {
  const main = document.createElement('main');
  main.style.cssText = 'position:absolute;top:0;left:0;width:100%;margin:0;padding:0;display:flex;flex-direction:column';
  host.style.cssText = 'margin:8px auto;padding:12px;border:1px solid';
  main.appendChild(host);
  document.body.appendChild(main);
  return main;
}

/** A spec with enough operations that the navigator is far taller than a phone screen. */
function longSpec(): OpenApiSpec {
  const paths: OpenApiSpec['paths'] = {};
  for (let i = 0; i < 40; i++) {
    paths[`/bff/admin/backing-services/{id}/endpoint-${i}`] = {
      get: { tags: [`Group ${i % 5}`], summary: `read thing ${i}`, parameters: [{ name: 'id', in: 'path', required: true, schema: { type: 'string' } }] },
    };
  }
  return { openapi: '3.0.1', info: { title: 'hugmesh-admin-bff-api', version: '0.1' }, paths };
}

describe('DocsShellComponent at phone width (GUI-30)', () => {
  let fixture: ComponentFixture<DocsShellComponent>;
  let httpMock: HttpTestingController;
  let shell: HTMLElement | null = null;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [DocsShellComponent],
      providers: [provideHttpClient(), provideHttpClientTesting()],
    }).compileComponents();
    fixture = TestBed.createComponent(DocsShellComponent);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(async () => {
    httpMock.verify();
    shell?.remove();
    shell = null;
    await setViewportWidth(null);
  });

  /** Load the spec, select an operation so the pane shows a real reference, mount in the shell. */
  function render(spec: OpenApiSpec = longSpec()): HTMLElement {
    fixture.detectChanges();
    httpMock.expectOne(SPECS.admin.primary).flush(spec);
    fixture.detectChanges();
    fixture.componentInstance.select(fixture.componentInstance.operations()[0]);
    fixture.detectChanges();
    const host = fixture.nativeElement as HTMLElement;
    shell = mountInShell(host);
    return host;
  }

  const box = (host: HTMLElement, sel: string) => host.querySelector<HTMLElement>(sel)!.getBoundingClientRect();

  for (const width of PHONE_WIDTHS) {
    it(`fits a ${width}px viewport: the view ends at the page edge`, async () => {
      const host = render();
      await setViewportWidth(width);
      const edge = document.documentElement.clientWidth;
      expect(Math.round(host.getBoundingClientRect().right)).toBeLessThanOrEqual(edge);
    });

    it(`stacks the navigator above a full-width detail pane at ${width}px`, async () => {
      const host = render();
      await setViewportWidth(width);
      const nav = box(host, '.nav');
      const pane = box(host, '.pane');
      const content = host.clientWidth - 24; // less the shell's 12px padding either side
      expect(pane.top).withContext('pane starts below the navigator').toBeGreaterThanOrEqual(nav.bottom - 1);
      expect(pane.width).withContext('pane width').toBeGreaterThan(content * 0.9);
      expect(nav.width).withContext('navigator width').toBeGreaterThan(content * 0.9);
      // The version line is the text that broke one character per line.
      const version = box(host, '.meta span');
      expect(version.height).withContext('"v0.1" stays on one line').toBeLessThan(24);
    });

    it(`caps the navigator's height at ${width}px so the pane stays reachable`, async () => {
      const host = render();
      await setViewportWidth(width);
      const nav = host.querySelector<HTMLElement>('.nav')!;
      expect(nav.scrollHeight).withContext('precondition: the operation list is taller than the cap').toBeGreaterThan(window.innerHeight);
      expect(nav.getBoundingClientRect().height).toBeLessThanOrEqual(window.innerHeight * 0.45 + 1);
    });
  }

  // Just below the breakpoint (a small tablet), where a one-operation list is clearly
  // shorter than 300px: the stacked navigator must not keep the desktop 300px flex basis,
  // which in a column becomes a 300px HEIGHT and leaves a band of empty navigator.
  it('sizes a short navigator to its content just below the breakpoint', async () => {
    const short: OpenApiSpec = {
      openapi: '3.0.1',
      info: { title: 'hugmesh-admin-bff-api', version: '0.1' },
      paths: { '/bff/admin/things': { get: { tags: ['Things'], summary: 'list things' } } },
    };
    const host = render(short);
    await setViewportWidth(700);
    const nav = host.querySelector<HTMLElement>('.nav')!;
    const top = nav.getBoundingClientRect().top;
    const contentHeight = Math.max(...Array.from(nav.children).map((c) => c.getBoundingClientRect().bottom)) - top;
    expect(contentHeight).withContext('precondition: the short list is shorter than 300px').toBeLessThan(290);
    expect(nav.getBoundingClientRect().height).toBeLessThanOrEqual(contentHeight + 2);
  });

  it('keeps the navigator beside the pane on a desktop viewport', async () => {
    const host = render();
    await setViewportWidth(1280);
    const nav = box(host, '.nav');
    const pane = box(host, '.pane');
    // 300px plus its 1px right border
    expect(nav.width).toBeGreaterThanOrEqual(300);
    expect(nav.width).toBeLessThanOrEqual(301);
    expect(pane.left).toBeGreaterThanOrEqual(nav.right - 1);
    expect(Math.abs(pane.top - nav.top)).toBeLessThan(1);
  });
});
