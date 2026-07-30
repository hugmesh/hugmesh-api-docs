import { bootstrapApplication } from '@angular/platform-browser';
import { provideRouter } from '@angular/router';
import { provideHttpClient } from '@angular/common/http';
import { AppComponent } from './app/app.component';
import { routes } from './app/app.routes';

// The standalone dev shell needs HttpClient because DocsShell fetches the
// OpenAPI spec. When federated into the hugmesh.systems host, the host
// provides HttpClient app-wide; this only covers `ng serve api-docs`.
bootstrapApplication(AppComponent, {
  providers: [provideRouter(routes), provideHttpClient()],
}).catch((err) => console.error(err));
