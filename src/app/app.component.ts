import { Component } from '@angular/core';
import { RouterOutlet } from '@angular/router';

/**
 * Standalone dev shell for the api-docs remote. Only used when this remote is
 * run on its own (`ng serve api-docs`); in production the hugmesh.systems
 * host federates `./routes` (API_DOCS_ROUTES) directly — this shell is not
 * loaded. It supplies the skip link + a <main id="main"> landmark so the remote
 * is keyboard-accessible when served standalone.
 */
@Component({
  selector: 'hug-api-docs-root',
  standalone: true,
  imports: [RouterOutlet],
  templateUrl: './app.component.html',
  styleUrl: './app.component.scss',
})
export class AppComponent {}
