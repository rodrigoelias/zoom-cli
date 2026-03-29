/**
 * HTTP Client for Zoom API
 * 
 * Handles:
 * - Making authenticated requests to Zoom API
 * - Session/auth expiry detection
 * - CSRF token management
 * - Error handling and validation
 */

import axios, { AxiosInstance, AxiosError } from 'axios';

export interface ZoomHttpClientConfig {
  cookies: Record<string, string>;
  csrfToken?: string;
  baseUrl?: string;
  timeout?: number;
}

export interface ApiResponse<T = any> {
  status: number;
  data: T;
  headers: Record<string, string>;
}

export class ZoomHttpClient {
  private client: AxiosInstance;
  private cookies: Record<string, string>;
  private csrfToken?: string;

  constructor(config: ZoomHttpClientConfig) {
    this.cookies = config.cookies;
    this.csrfToken = config.csrfToken;

    this.client = axios.create({
      baseURL: config.baseUrl || 'https://zoom.us',
      timeout: config.timeout || 30000,
      withCredentials: true,
    });

    // Add request interceptor to include cookies and CSRF token
    this.client.interceptors.request.use((requestConfig) => {
      requestConfig.headers['Cookie'] = this.getCookieHeader();
      
      if (this.csrfToken && requestConfig.method?.toLowerCase() !== 'get') {
        requestConfig.headers['X-CSRF-Token'] = this.csrfToken;
        requestConfig.headers['zoom-csrftoken'] = this.csrfToken;
      }

      // Common Zoom headers
      requestConfig.headers['Accept'] = 'application/json';
      requestConfig.headers['User-Agent'] = 'zoom-cli/1.0';
      requestConfig.headers['X-Requested-With'] = 'XMLHttpRequest';

      return requestConfig;
    });
  }

  private getCookieHeader(): string {
    return Object.entries(this.cookies)
      .map(([name, value]) => `${name}=${value}`)
      .join('; ');
  }

  /**
   * Check if response indicates auth expiry
   */
  private isAuthExpired(response: any): boolean {
    // JSON error response
    if (response?.data?.errorCode === 201 || response?.data?.errorCode === 401) {
      return true;
    }

    // String errors
    if (typeof response?.data === 'string') {
      if (response.data.includes('User not login') ||
          response.data.includes('login.microsoftonline.com') ||
          response.data.includes('SAMLRequest')) {
        return true;
      }
    }

    // HTTP status code
    if (response?.status === 401 || response?.status === 403) {
      return true;
    }

    return false;
  }

  /**
   * GET request
   */
  async get<T = any>(path: string, options?: any): Promise<ApiResponse<T>> {
    try {
      const response = await this.client.get(path, options);
      return {
        status: response.status,
        data: response.data,
        headers: response.headers as Record<string, string>,
      };
    } catch (error) {
      this.handleError(error);
      throw error;
    }
  }

  /**
   * POST request
   */
  async post<T = any>(
    path: string,
    data?: any,
    options?: any
  ): Promise<ApiResponse<T>> {
    try {
      const response = await this.client.post(path, data, {
        ...options,
        headers: {
          'Content-Type': 'application/json',
          ...options?.headers,
        },
      });
      return {
        status: response.status,
        data: response.data,
        headers: response.headers as Record<string, string>,
      };
    } catch (error) {
      this.handleError(error);
      throw error;
    }
  }

  /**
   * PUT request
   */
  async put<T = any>(
    path: string,
    data?: any,
    options?: any
  ): Promise<ApiResponse<T>> {
    try {
      const response = await this.client.put(path, data, {
        ...options,
        headers: {
          'Content-Type': 'application/json',
          ...options?.headers,
        },
      });
      return {
        status: response.status,
        data: response.data,
        headers: response.headers as Record<string, string>,
      };
    } catch (error) {
      this.handleError(error);
      throw error;
    }
  }

  /**
   * DELETE request
   */
  async delete<T = any>(path: string, options?: any): Promise<ApiResponse<T>> {
    try {
      const response = await this.client.delete(path, options);
      return {
        status: response.status,
        data: response.data,
        headers: response.headers as Record<string, string>,
      };
    } catch (error) {
      this.handleError(error);
      throw error;
    }
  }

  /**
   * Update CSRF token
   */
  setCsrfToken(token: string): void {
    this.csrfToken = token;
  }

  /**
   * Update cookies
   */
  setCookies(cookies: Record<string, string>): void {
    this.cookies = cookies;
  }

  /**
   * Get current cookies
   */
  getCookies(): Record<string, string> {
    return { ...this.cookies };
  }

  private handleError(error: any): void {
    if (error.response) {
      if (this.isAuthExpired(error.response)) {
        throw new AuthExpiredError(
          `Auth expired: ${error.response.status} ${error.response.statusText}`
        );
      }

      throw new ApiError(
        `API Error: ${error.response.status}`,
        error.response.status,
        error.response.data
      );
    } else if (error.request) {
      throw new NetworkError('No response from server');
    } else {
      throw error;
    }
  }
}

export class ApiError extends Error {
  constructor(
    message: string,
    public status: number,
    public data: any
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

export class AuthExpiredError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'AuthExpiredError';
  }
}

export class NetworkError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'NetworkError';
  }
}
