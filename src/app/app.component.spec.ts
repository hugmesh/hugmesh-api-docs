import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { AppComponent } from './app.component';
import { routes } from './app.routes';

/**
 * The standalone dev shell (only used by `ng serve api-docs`). It must supply
 * the a11y landmarks that the federated host normally provides — a skip link and
 * a focusable <main id="main"> — plus the <router-outlet> that mounts the
 * exposed API_DOCS_ROUTES so the remote is browsable on its own.
 */
describe('AppComponent (standalone dev shell)', () => {
  let fixture: ComponentFixture<AppComponent>;
  let el: HTMLElement;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [AppComponent],
      providers: [provideRouter(routes)],
    }).compileComponents();
    fixture = TestBed.createComponent(AppComponent);
    fixture.detectChanges();
    el = fixture.nativeElement as HTMLElement;
  });

  it('creates the dev shell', () => {
    expect(fixture.componentInstance).toBeTruthy();
  });

  it('renders a router-outlet so ADMIN_ROUTES can mount standalone', () => {
    expect(el.querySelector('router-outlet')).not.toBeNull();
  });

  describe('accessibility', () => {
    it('exposes a skip link targeting the main landmark', () => {
      const skip = el.querySelector<HTMLAnchorElement>('a.skip');
      expect(skip).withContext('skip link present').not.toBeNull();
      expect(skip!.getAttribute('href')).toBe('#main');
      expect(skip!.textContent!.trim().length).toBeGreaterThan(0);
    });

    it('renders a focusable <main id="main"> landmark for the skip target', () => {
      const main = el.querySelector<HTMLElement>('main#main');
      expect(main).withContext('<main id="main"> present').not.toBeNull();
      expect(main!.getAttribute('tabindex')).toBe('-1');
    });

    it('uses a native <a> for the skip link so it is keyboard-reachable + Enter-activatable', () => {
      const skip = el.querySelector<HTMLAnchorElement>('a.skip')!;
      // A real anchor with an in-page href is Tab-reachable and Enter moves the
      // viewport + (with tabindex=-1 target) focus to <main> — no JS handler,
      // no positive tabindex needed.
      expect(skip.tagName).toBe('A');
      const ti = skip.getAttribute('tabindex');
      expect(ti === null || Number(ti) <= 0)
        .withContext('skip link has no positive tabindex')
        .toBe(true);
      // The skip target it points at must be focusable so focus actually lands
      // there (tabindex=-1 makes <main> programmatically focusable).
      const targetId = skip.getAttribute('href')!.slice(1);
      const target = el.querySelector<HTMLElement>(`#${targetId}`)!;
      expect(target).withContext('skip target exists').not.toBeNull();
      expect(target.getAttribute('tabindex')).toBe('-1');
    });
  });
});
