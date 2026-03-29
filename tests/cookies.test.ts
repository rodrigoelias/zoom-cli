/**
 * Unit Tests: Cookie Management
 * 
 * Test all cookie parsing, serialization, and validation logic
 * WITHOUT needing real browser or network access
 */

import {
  parseRawCookieString,
  serializeToRawCookieString,
  formatNetscapeCookies,
  parseNetscapeCookies,
  getCookieHeader,
  validateCookies,
  mergeCookies,
  Cookie,
} from '../src/cookies';

describe('Cookie Management', () => {
  describe('parseRawCookieString', () => {
    it('should parse simple cookie string', () => {
      const raw = 'session=abc123; user=john';
      const result = parseRawCookieString(raw);
      
      expect(result).toEqual({
        session: 'abc123',
        user: 'john',
      });
    });

    it('should handle whitespace', () => {
      const raw = 'session=abc123 ; user=john ; token=xyz';
      const result = parseRawCookieString(raw);
      
      expect(result).toEqual({
        session: 'abc123',
        user: 'john',
        token: 'xyz',
      });
    });

    it('should handle empty string', () => {
      const result = parseRawCookieString('');
      expect(result).toEqual({});
    });

    it('should skip malformed pairs', () => {
      const raw = 'valid=yes; broken; also_valid=yes2';
      const result = parseRawCookieString(raw);
      
      expect(result).toEqual({
        valid: 'yes',
        also_valid: 'yes2',
      });
    });

    it('should handle values with equals signs', () => {
      const raw = 'jwt=eyJhbGc=.eyJzdWI=.SflKxw=';
      const result = parseRawCookieString(raw);
      
      expect(result.jwt).toBe('eyJhbGc=.eyJzdWI=.SflKxw=');
    });
  });

  describe('serializeToRawCookieString', () => {
    it('should serialize cookies to raw format', () => {
      const cookies: Cookie[] = [
        { name: 'session', value: 'abc123', domain: 'zoom.us', path: '/', httpOnly: true, secure: true },
        { name: 'user', value: 'john', domain: 'zoom.us', path: '/', httpOnly: false, secure: true },
      ];

      const result = serializeToRawCookieString(cookies);
      expect(result).toBe('session=abc123; user=john');
    });

    it('should handle empty cookie list', () => {
      const result = serializeToRawCookieString([]);
      expect(result).toBe('');
    });
  });

  describe('Netscape format', () => {
    it('should format cookies to Netscape format', () => {
      const cookies: Cookie[] = [
        {
          name: 'session',
          value: 'abc123',
          domain: 'zoom.us',
          path: '/',
          expires: 1234567890,
          httpOnly: true,
          secure: true,
        },
      ];

      const result = formatNetscapeCookies(cookies);
      
      expect(result).toContain('#HttpOnly_');
      expect(result).toContain('zoom.us');
      expect(result).toContain('session');
      expect(result).toContain('abc123');
    });

    it('should parse Netscape format back', () => {
      const netscape = `# Netscape HTTP Cookie File
#HttpOnly_.zoom.us	TRUE	/	TRUE	1234567890000	session	abc123
.example.com	TRUE	/path	FALSE	0	user	john`;

      const result = parseNetscapeCookies(netscape);

      expect(result).toHaveLength(2);
      expect(result[0].name).toBe('session');
      expect(result[0].httpOnly).toBe(true);
      expect(result[0].secure).toBe(true);
      expect(result[1].name).toBe('user');
      expect(result[1].httpOnly).toBe(false);
    });

    it('should handle Netscape roundtrip', () => {
      const original: Cookie[] = [
        {
          name: 'zm_jwt',
          value: 'eyJhbGc...',
          domain: '.zoom.us',
          path: '/',
          expires: 1704067200,
          httpOnly: true,
          secure: true,
        },
        {
          name: 'tracking',
          value: 'xyz',
          domain: 'zoom.us',
          path: '/meetings',
          httpOnly: false,
          secure: false,
        },
      ];

      const formatted = formatNetscapeCookies(original);
      const parsed = parseNetscapeCookies(formatted);

      expect(parsed).toHaveLength(original.length);
      expect(parsed[0].name).toBe(original[0].name);
      expect(parsed[0].value).toBe(original[0].value);
      expect(parsed[0].httpOnly).toBe(original[0].httpOnly);
    });
  });

  describe('getCookieHeader', () => {
    it('should generate Cookie header', () => {
      const cookies = {
        session: 'abc123',
        user: 'john',
        token: 'xyz789',
      };

      const result = getCookieHeader(cookies);
      
      expect(result).toContain('session=abc123');
      expect(result).toContain('user=john');
      expect(result).toContain('token=xyz789');
    });

    it('should handle empty cookies', () => {
      const result = getCookieHeader({});
      expect(result).toBe('');
    });
  });

  describe('validateCookies', () => {
    it('should validate non-empty cookies', () => {
      const cookies = {
        zoom_us_sid: 'xxx',
        zm_jwt: 'yyy',
      };

      const result = validateCookies(cookies);
      
      expect(result.valid).toBe(true);
      expect(result.warnings).toHaveLength(0);
    });

    it('should warn on empty cookies', () => {
      const result = validateCookies({});
      
      expect(result.valid).toBe(false);
      expect(result.warnings).toContain('No cookies found');
    });

    it('should warn on missing Zoom cookies', () => {
      const cookies = {
        random: 'value',
        other: 'cookie',
      };

      const result = validateCookies(cookies);
      
      expect(result.valid).toBe(false);
      expect(result.warnings).toContain('No Zoom-specific cookies found');
    });
  });

  describe('mergeCookies', () => {
    it('should merge cookie sets', () => {
      const base = { session: 'abc', user: 'john' };
      const updates = { token: 'xyz' };

      const result = mergeCookies(base, updates);
      
      expect(result).toEqual({
        session: 'abc',
        user: 'john',
        token: 'xyz',
      });
    });

    it('should override with newer values', () => {
      const base = { session: 'old', user: 'john' };
      const updates = { session: 'new' };

      const result = mergeCookies(base, updates);
      
      expect(result.session).toBe('new');
      expect(result.user).toBe('john');
    });
  });
});
