import { screenReaderName } from './a11y';

/**
 * screenReaderName is the ASCII-announce util: it keeps a control's ACCESSIBLE
 * name clean for screen readers when the visible label carries non-ASCII glyphs.
 * Pure-ASCII input (the common REST-path case) must pass through untouched.
 */
describe('screenReaderName', () => {
  it('returns pure-ASCII input unchanged', () => {
    expect(screenReaderName('GET /bff/admin/things')).toBe('GET /bff/admin/things');
    expect(screenReaderName('id, required path parameter (string)')).toBe(
      'id, required path parameter (string)',
    );
  });

  it('returns an empty string for null/undefined', () => {
    expect(screenReaderName(null)).toBe('');
    expect(screenReaderName(undefined)).toBe('');
  });

  it('folds common typographic punctuation to ASCII', () => {
    expect(screenReaderName('Admin — BFF')).toBe('Admin - BFF');
    expect(screenReaderName('Users · Roles')).toBe('Users . Roles');
    expect(screenReaderName('load more…')).toBe('load more...');
    expect(screenReaderName('“quoted”')).toBe('"quoted"');
  });

  it('strips diacritics to their ASCII base letter', () => {
    expect(screenReaderName('Café')).toBe('Cafe');
    expect(screenReaderName('naïve')).toBe('naive');
  });

  it('drops un-mapped non-ASCII glyphs rather than spelling their codepoint', () => {
    // An emoji has no ASCII equivalent — it is dropped, not read as "U+1F600".
    expect(screenReaderName('done \u{1F600}')).toBe('done');
  });
});
