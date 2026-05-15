import { encodeBase62 } from './base62';

describe('encodeBase62', () => {
  it('encodes 0', () => {
    expect(encodeBase62(0n)).toBe('0');
  });

  it('encodes 1', () => {
    expect(encodeBase62(1n)).toBe('1');
  });

  it('encodes 61 as the last single char (Z)', () => {
    expect(encodeBase62(61n)).toBe('Z');
  });

  it('encodes 62 as "10" (roll over)', () => {
    expect(encodeBase62(62n)).toBe('10');
  });

  it('produces only characters from the allowed alphabet', () => {
    const alphabet = new Set('0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ');
    for (const id of [1n, 100n, 999n, 123456789n, 3_500_000_000_000n]) {
      for (const char of encodeBase62(id)) {
        expect(alphabet.has(char)).toBe(true);
      }
    }
  });

  it('produces at most 7 chars for IDs within 365 billion', () => {
    expect(encodeBase62(365_000_000_000n).length).toBeLessThanOrEqual(7);
  });

  it('is deterministic', () => {
    expect(encodeBase62(42n)).toBe(encodeBase62(42n));
  });
});
