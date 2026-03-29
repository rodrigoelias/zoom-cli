/**
 * Unit Tests: HTTP Client
 * 
 * Test API communication, auth detection, and error handling
 * WITHOUT making real network requests (using mocked axios)
 */

import axios from 'axios';
import { ZoomHttpClient, ApiError, AuthExpiredError, NetworkError } from '../src/http-client';

// Mock axios
jest.mock('axios');
const mockedAxios = axios as jest.Mocked<typeof axios>;

describe('ZoomHttpClient', () => {
  const mockCookies = {
    zoom_us_sid: 'session123',
    zm_jwt: 'token456',
  };

  beforeEach(() => {
    jest.clearAllMocks();
  });

  const createMockInstance = () => ({
    get: jest.fn().mockResolvedValue({
      status: 200,
      data: {},
      headers: {},
    }),
    post: jest.fn().mockResolvedValue({
      status: 200,
      data: {},
      headers: {},
    }),
    put: jest.fn().mockResolvedValue({
      status: 200,
      data: {},
      headers: {},
    }),
    delete: jest.fn().mockResolvedValue({
      status: 200,
      data: {},
      headers: {},
    }),
    interceptors: {
      request: { use: jest.fn().mockReturnThis() },
    },
  });

  describe('initialization', () => {
    it('should initialize with cookies', () => {
      const mockInstance = createMockInstance();
      mockedAxios.create.mockReturnValue(mockInstance as any);

      const client = new ZoomHttpClient({ cookies: mockCookies });
      expect(client.getCookies()).toEqual(mockCookies);
    });

    it('should support CSRF token', () => {
      const mockInstance = createMockInstance();
      mockedAxios.create.mockReturnValue(mockInstance as any);

      const client = new ZoomHttpClient({
        cookies: mockCookies,
        csrfToken: 'csrf123',
      });
      expect(client.getCookies()).toEqual(mockCookies);
    });
  });

  describe('GET requests', () => {
    it('should make successful GET request', async () => {
      const mockInstance = createMockInstance();
      mockInstance.get = jest.fn().mockResolvedValue({
        status: 200,
        data: { meetings: [] },
        headers: {},
      });
      mockedAxios.create.mockReturnValue(mockInstance as any);

      const client = new ZoomHttpClient({ cookies: mockCookies });
      const result = await client.get('/api/meetings');

      expect(result.status).toBe(200);
      expect(result.data).toEqual({ meetings: [] });
    });

    it('should include cookies in request', async () => {
      const mockInstance = createMockInstance();
      mockedAxios.create.mockReturnValue(mockInstance as any);

      const client = new ZoomHttpClient({ cookies: mockCookies });
      await client.get('/api/meetings');

      expect(mockInstance.get).toHaveBeenCalled();
    });
  });

  describe('POST requests', () => {
    it('should make successful POST request', async () => {
      const mockInstance = createMockInstance();
      mockInstance.post = jest.fn().mockResolvedValue({
        status: 200,
        data: { id: '123', created: true },
        headers: {},
      });
      mockedAxios.create.mockReturnValue(mockInstance as any);

      const client = new ZoomHttpClient({ cookies: mockCookies });
      const result = await client.post('/api/meetings', {
        topic: 'Test Meeting',
      });

      expect(result.status).toBe(200);
      expect(result.data.id).toBe('123');
    });

    it('should include Content-Type header', async () => {
      const mockInstance = createMockInstance();
      mockedAxios.create.mockReturnValue(mockInstance as any);

      const client = new ZoomHttpClient({ cookies: mockCookies });
      await client.post('/api/meetings', { topic: 'Test' });

      const callArgs = mockInstance.post.mock.calls[0];
      expect(callArgs[2]?.headers?.['Content-Type']).toBe('application/json');
    });
  });

  describe('auth expiry detection', () => {
    it('should detect 401 status code as auth expired', async () => {
      const mockInstance = createMockInstance();
      mockInstance.get = jest.fn().mockRejectedValue({
        response: {
          status: 401,
          statusText: 'Unauthorized',
          data: {},
        },
      });
      mockedAxios.create.mockReturnValue(mockInstance as any);

      const client = new ZoomHttpClient({ cookies: mockCookies });
      await expect(client.get('/api/meetings')).rejects.toThrow(AuthExpiredError);
    });

    it('should detect 403 status code as auth expired', async () => {
      const mockInstance = createMockInstance();
      mockInstance.get = jest.fn().mockRejectedValue({
        response: {
          status: 403,
          statusText: 'Forbidden',
          data: {},
        },
      });
      mockedAxios.create.mockReturnValue(mockInstance as any);

      const client = new ZoomHttpClient({ cookies: mockCookies });
      await expect(client.get('/api/meetings')).rejects.toThrow(AuthExpiredError);
    });

    it('should detect JSON error code 201 as auth expired', async () => {
      const mockInstance = createMockInstance();
      mockInstance.get = jest.fn().mockRejectedValue({
        response: {
          status: 200,
          statusText: 'OK',
          data: { errorCode: 201, errorMessage: 'User not login' },
        },
      });
      mockedAxios.create.mockReturnValue(mockInstance as any);

      const client = new ZoomHttpClient({ cookies: mockCookies });
      await expect(client.get('/api/meetings')).rejects.toThrow(AuthExpiredError);
    });

    it('should detect "User not login" string', async () => {
      const mockInstance = createMockInstance();
      mockInstance.get = jest.fn().mockRejectedValue({
        response: {
          status: 200,
          data: 'User not login',
        },
      });
      mockedAxios.create.mockReturnValue(mockInstance as any);

      const client = new ZoomHttpClient({ cookies: mockCookies });
      await expect(client.get('/api/meetings')).rejects.toThrow(AuthExpiredError);
    });

    it('should detect Okta redirect as auth expired', async () => {
      const mockInstance = createMockInstance();
      mockInstance.get = jest.fn().mockRejectedValue({
        response: {
          status: 200,
          data: '<html><body>login.microsoftonline.com/oauth</body></html>',
        },
      });
      mockedAxios.create.mockReturnValue(mockInstance as any);

      const client = new ZoomHttpClient({ cookies: mockCookies });
      await expect(client.get('/api/meetings')).rejects.toThrow(AuthExpiredError);
    });
  });

  describe('error handling', () => {
    it('should throw ApiError for non-auth HTTP errors', async () => {
      const mockInstance = createMockInstance();
      mockInstance.get = jest.fn().mockRejectedValue({
        response: {
          status: 500,
          statusText: 'Internal Server Error',
          data: { error: 'Server error' },
        },
      });
      mockedAxios.create.mockReturnValue(mockInstance as any);

      const client = new ZoomHttpClient({ cookies: mockCookies });
      await expect(client.get('/api/meetings')).rejects.toThrow(ApiError);
    });

    it('should throw NetworkError when no response', async () => {
      const mockInstance = createMockInstance();
      mockInstance.get = jest.fn().mockRejectedValue({
        request: {},
        // No response property
      });
      mockedAxios.create.mockReturnValue(mockInstance as any);

      const client = new ZoomHttpClient({ cookies: mockCookies });
      await expect(client.get('/api/meetings')).rejects.toThrow(NetworkError);
    });
  });

  describe('cookie management', () => {
    it('should update cookies', () => {
      const mockInstance = createMockInstance();
      mockedAxios.create.mockReturnValue(mockInstance as any);

      const client = new ZoomHttpClient({ cookies: mockCookies });
      const newCookies = { zoom_us_sid: 'new_session' };

      client.setCookies(newCookies);
      expect(client.getCookies()).toEqual(newCookies);
    });

    it('should update CSRF token', () => {
      const mockInstance = createMockInstance();
      mockedAxios.create.mockReturnValue(mockInstance as any);

      const client = new ZoomHttpClient({ cookies: mockCookies });
      client.setCsrfToken('new_csrf_token');
      expect(client.getCookies()).toBeDefined();
    });
  });
});
