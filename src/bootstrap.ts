import { bootstrapApplication } from '@angular/platform-browser';
import { provideRouter } from '@angular/router';
import { provideHttpClient, withInterceptors } from '@angular/common/http';
import { AppComponent } from './app/app.component';
import { routes } from './app/app.routes';
import { credentialsInterceptor } from './app/http/credentials.interceptor';

// The standalone dev shell needs HttpClient because DocsShell fetches the
// OpenAPI spec. When federated into the hugmesh.net host, the host
// provides HttpClient app-wide; this only covers `ng serve api-docs`.
// `credentialsInterceptor` mirrors the host's `bearerInterceptor` so the live
// /v3/api-docs fallback rides the session cookie here too.
bootstrapApplication(AppComponent, {
  providers: [
    provideRouter(routes),
    provideHttpClient(withInterceptors([credentialsInterceptor])),
  ],
}).catch((err) => console.error(err));
