import { Injectable, signal, computed } from '@angular/core';

/**
 * The shape of the HugMesh session object persisted to localStorage under
 * the key `hug.session`. Written by the login remote once the native-login
 * flow (login-ui POSTing credentials to a user-bff `/bff/login`-style
 * endpoint, validated against Casdoor server-side rather than a browser
 * redirect through Casdoor) completes and registration is confirmed.
 */
export interface SnapSession {
  /** Casdoor-qualified identity string, e.g. `google:alice@gmail.com`. */
  id: string;
  /** Human-readable display label — email address or Discord handle. */
  label: string;
  /** OAuth provider used for this sign-in. */
  provider: 'google' | 'discord';
  /** Casdoor role names assigned to this user, e.g. `['admin']`. */
  roles: string[];
  /**
   * Bearer token issued by the BFF for API calls that require authentication.
   * Injected into the Try-it-out bearer-token override by
   * `ApiExplorerComponent.readSessionToken` so the interactive request
   * builder (this remote's own OpenAPI navigator, not Swagger UI) can reach
   * ROLE_ADMIN-gated endpoints.
   *
   * TODO: confirm this is still populated under native login — the
   * platform's httpOnly `bff_` session cookie isn't client-readable, and
   * other HugMesh frontends had to drop an equivalent field for that
   * reason (see README's "Known Gaps" section).
   */
  bffToken: string;
  /**
   * Set to `true` once the post-SSO registration flow (username, acceptance of
   * terms, etc.) has finished. Guards the Matrix and Mastodon micro-frontends:
   * they are not unlocked until this flag is set.
   */
  registrationComplete: boolean;
  /** Matrix access token and fully-qualified user ID, or `null` if not linked. */
  matrix: { token: string; userId: string } | null;
  /** Mastodon bearer token, or `null` if not linked. */
  mastodon: { token: string } | null;
}

/**
 * Singleton service that owns the logged-in session for the entire
 * hugmesh.systems micro-frontend mesh.
 *
 * The session is persisted as JSON in `localStorage['hug.session']` so it
 * survives page refreshes. Because each native-federation remote instantiates
 * its own copy of this service (Angular DI is per-injector), the service
 * subscribes to two synchronisation events to stay in lockstep across all
 * remotes and browser tabs:
 *
 * - A same-document `CustomEvent` named `hug-session-change` — dispatched by
 *   whichever instance last wrote, so sibling remotes embedded in the same
 *   document page update immediately without a storage round-trip.
 * - The native `StorageEvent` — keeps separate browser tabs in sync.
 *
 * Derived computed signals (`loggedIn`, `isAdmin`, `fullyRegistered`) are read
 * by route guards and nav components throughout the shell.
 *
 * @see SnapSession
 * @see adminGuard
 */
@Injectable({ providedIn: 'root' })
export class SessionService {
  /** localStorage key under which the {@link SnapSession} JSON is stored. */
  private readonly key = 'hug.session';
  /** Custom event name broadcast within a single document when the session changes. */
  private readonly channel = 'hug-session-change';

  /** The current session, or `null` when logged out. Initialised from localStorage. */
  readonly session = signal<SnapSession | null>(this.load());

  /** `true` when a non-null session exists in storage. */
  readonly loggedIn = computed(() => this.session() !== null);

  /**
   * `true` when the current session includes the `admin` Casdoor role.
   * Consumed by `adminGuard` and the admin-nav visibility check.
   */
  readonly isAdmin = computed(() => (this.session()?.roles ?? []).includes('admin'));

  /**
   * `true` once the post-SSO registration flow has been completed.
   * Matrix and Mastodon micro-frontends are gated on this flag.
   */
  readonly fullyRegistered = computed(() => this.session()?.registrationComplete === true);

  constructor() {
    // The host shell and each federated remote each hold their OWN SessionService
    // instance over the same localStorage key. Re-read on a same-document broadcast
    // (dispatched by whichever instance wrote) and on cross-tab storage events, so
    // every nav/guard reading this signal stays in sync — e.g. the login remote
    // completing registration must unlock the host shell's Matrix/Mastodon nav.
    if (typeof window !== 'undefined') {
      window.addEventListener(this.channel, () => this.session.set(this.load()));
      window.addEventListener('storage', (e) => { if (e.key === this.key) this.session.set(this.load()); });
    }
  }

  /**
   * Reads and parses the raw JSON from localStorage.
   * Returns `null` if the key is absent or the value cannot be parsed.
   */
  private load(): SnapSession | null {
    try { const raw = localStorage.getItem(this.key); return raw ? JSON.parse(raw) : null; }
    catch { return null; }
  }

  /**
   * Persists a new session to localStorage, updates the signal, and broadcasts
   * the change to sibling remotes in the same document.
   *
   * @param s - The fully-formed session object to store.
   */
  set(s: SnapSession): void { localStorage.setItem(this.key, JSON.stringify(s)); this.session.set(s); this.broadcast(); }

  /**
   * Merges a partial update into the current session.
   * Does nothing when there is no active session.
   *
   * @param p - Fields to merge into the existing {@link SnapSession}.
   */
  patch(p: Partial<SnapSession>): void { const s = this.session(); if (s) this.set({ ...s, ...p }); }

  /**
   * Removes the session from localStorage and signals all remotes + tabs to
   * treat the user as logged out.
   */
  clear(): void { localStorage.removeItem(this.key); this.session.set(null); this.broadcast(); }

  /**
   * Fires a same-document custom event so every `SessionService` instance
   * embedded in the current page re-reads the updated value from localStorage.
   */
  private broadcast(): void { if (typeof window !== 'undefined') window.dispatchEvent(new Event(this.channel)); }
}
