/**
 * a11y helpers shared across the api-docs remote.
 *
 * `screenReaderName` — the HugMesh ASCII-announce util. Some visible labels
 * (OpenAPI tags, paths, service names) can contain non-ASCII glyphs (em dashes,
 * middots, smart quotes, decorative separators) that several screen readers
 * either skip silently or read out as their unhelpful Unicode name. When such a
 * string is used as a control's ACCESSIBLE NAME (aria-label), pass it through
 * this util so the announced name is a clean ASCII transliteration while the
 * VISIBLE text keeps its original glyphs.
 *
 * It is a deliberately small, dependency-free fold of the most common
 * typographic punctuation to ASCII, plus a NFKD diacritic strip; anything else
 * non-ASCII is dropped (rather than announced as "U+XXXX"). Pure ASCII input is
 * returned unchanged so the overwhelmingly-common case (REST paths, HTTP verbs)
 * pays no cost and the announced name equals the visible one.
 */
const PUNCT_MAP: Record<string, string> = {
  '–': '-', // en dash
  '—': '-', // em dash
  '−': '-', // minus sign
  '·': '.', // middle dot
  '•': '*', // bullet
  '…': '...', // horizontal ellipsis
  ' ': ' ', // non-breaking space
  '‘': "'", // left single quote
  '’': "'", // right single quote
  '“': '"', // left double quote
  '”': '"', // right double quote
  '×': 'x', // multiplication sign
  '→': '->', // rightwards arrow
};

export function screenReaderName(input: string | null | undefined): string {
  if (input == null) return '';
  // Fast path: already pure printable ASCII — announced name == visible name.
  // eslint-disable-next-line no-control-regex
  if (/^[\x20-\x7e]*$/.test(input)) return input;

  let out = '';
  // Normalise so accented letters decompose to base + combining mark, then we
  // strip the marks below — "Café" announces as "Cafe", not "Caf".
  for (const ch of input.normalize('NFKD')) {
    if (PUNCT_MAP[ch] !== undefined) {
      out += PUNCT_MAP[ch];
      continue;
    }
    const code = ch.codePointAt(0)!;
    // Keep printable ASCII.
    if (code >= 0x20 && code <= 0x7e) {
      out += ch;
      continue;
    }
    // Drop combining diacritical marks (U+0300–U+036F) and any other
    // non-ASCII glyph rather than letting a screen reader spell its codepoint.
  }
  // Collapse any whitespace runs the substitutions may have produced.
  return out.replace(/\s+/g, ' ').trim();
}
