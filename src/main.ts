/**
 * Entry point for the api-docs native-federation remote.
 *
 * `initFederation` must run before the Angular bootstrap so this remote's
 * exposed modules (declared in `federation.config.js`) are registered with
 * native-federation and any eagerly-imported federation dependencies are
 * resolved. As a remote (not a host), this call takes no manifest argument
 * — manifest registration is the host app's responsibility. The actual
 * Angular bootstrap is deferred to `./bootstrap` which is dynamically
 * imported after federation initialisation completes.
 */
import { initFederation } from '@angular-architects/native-federation';

// Initialise native federation first, then bootstrap Angular.
// NOTE: the `.catch` below only logs a federation-init failure — it does not
// re-throw — so the chain still resolves and the subsequent `.then` always
// proceeds to bootstrap Angular, even if federation setup failed. Any error
// from the dynamic `import('./bootstrap')` itself is caught by the final
// `.catch` and logged the same way.
initFederation()
  .catch(err => console.error(err))
  .then(_ => import('./bootstrap'))
  .catch(err => console.error(err));
