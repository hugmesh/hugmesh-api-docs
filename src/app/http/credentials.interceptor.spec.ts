import { TestBed } from '@angular/core/testing';
import { HttpClient, provideHttpClient, withInterceptors } from '@angular/common/http';
import {
  HttpTestingController,
  provideHttpClientTesting,
} from '@angular/common/http/testing';
import { credentialsInterceptor } from './credentials.interceptor';

/**
 * Pins the standalone dev shell's single HttpClient credentials seam: every
 * outbound request carries the session cookie, so DocsShell's live
 * /v3/api-docs fallback reaches a ROLE_ADMIN-gated endpoint.
 */
describe('credentialsInterceptor', () => {
  let http: HttpClient;
  let ctrl: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(withInterceptors([credentialsInterceptor])),
        provideHttpClientTesting(),
      ],
    });
    http = TestBed.inject(HttpClient);
    ctrl = TestBed.inject(HttpTestingController);
  });

  afterEach(() => ctrl.verify());

  it('sets withCredentials on the live spec fallback request', () => {
    http.get('/bff/admin/v3/api-docs').subscribe();
    const req = ctrl.expectOne('/bff/admin/v3/api-docs');
    expect(req.request.withCredentials).toBeTrue();
    req.flush({});
  });

  it('sets withCredentials on the committed spec artifact too (harmless when anonymous)', () => {
    http.get('/assets/specs/openapi-admin.json').subscribe();
    const req = ctrl.expectOne('/assets/specs/openapi-admin.json');
    expect(req.request.withCredentials).toBeTrue();
    req.flush({});
  });

  it('adds no Authorization header — the gateway exchanges the cookie server-side', () => {
    http.get('/bff/admin/v3/api-docs').subscribe();
    const req = ctrl.expectOne('/bff/admin/v3/api-docs');
    expect(req.request.headers.has('Authorization')).toBeFalse();
    req.flush({});
  });
});
