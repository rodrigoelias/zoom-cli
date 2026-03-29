/**
 * Unit Tests: Zoom API Models
 * 
 * Test model validation and API response parsing
 */

import {
  validateMeeting,
  validateCreateMeetingRequest,
  parseApiError,
  ZoomMeeting,
  CreateMeetingRequest,
} from '../src/zoom-api';

describe('Zoom API Models', () => {
  describe('validateMeeting', () => {
    it('should validate valid meeting object', () => {
      const meeting: ZoomMeeting = {
        id: '123',
        uuid: 'uuid123',
        topic: 'Team Standup',
        type: 2,
        start_time: '2024-04-01T10:00:00Z',
        duration: 30,
        timezone: 'America/Los_Angeles',
        created_at: '2024-03-25T10:00:00Z',
        join_url: 'https://zoom.us/j/123',
        status: 'waiting',
        host_id: 'host123',
        host_email: 'host@example.com',
      };

      expect(validateMeeting(meeting)).toBe(true);
    });

    it('should reject missing id', () => {
      const meeting = {
        topic: 'Meeting',
        start_time: '2024-04-01T10:00:00Z',
      };

      expect(validateMeeting(meeting)).toBe(false);
    });

    it('should reject missing topic', () => {
      const meeting = {
        id: '123',
        start_time: '2024-04-01T10:00:00Z',
      };

      expect(validateMeeting(meeting)).toBe(false);
    });

    it('should reject missing start_time', () => {
      const meeting = {
        id: '123',
        topic: 'Meeting',
      };

      expect(validateMeeting(meeting)).toBe(false);
    });
  });

  describe('validateCreateMeetingRequest', () => {
    it('should validate valid request', () => {
      const request: CreateMeetingRequest = {
        topic: 'New Meeting',
        type: 2,
        start_time: '2024-04-01T10:00:00Z',
        duration: 60,
      };

      expect(validateCreateMeetingRequest(request)).toBe(true);
    });

    it('should require topic', () => {
      const request = {
        type: 2,
        start_time: '2024-04-01T10:00:00Z',
      };

      expect(validateCreateMeetingRequest(request)).toBe(false);
    });

    it('should require start_time for scheduled meetings (type 2)', () => {
      const request = {
        topic: 'Meeting',
        type: 2,
        // Missing start_time
      };

      expect(validateCreateMeetingRequest(request)).toBe(false);
    });

    it('should not require start_time for instant meetings (type 1)', () => {
      const request = {
        topic: 'Meeting',
        type: 1,
      };

      expect(validateCreateMeetingRequest(request)).toBe(true);
    });

    it('should validate with recurrence', () => {
      const request: CreateMeetingRequest = {
        topic: 'Weekly Meeting',
        type: 2,
        start_time: '2024-04-01T10:00:00Z',
        recurrence: {
          type: 2, // weekly
          repeat_interval: 1,
          weekly_days: 'MO,WE,FR',
        },
      };

      expect(validateCreateMeetingRequest(request)).toBe(true);
    });
  });

  describe('parseApiError', () => {
    it('should parse error with code and message', () => {
      const data = {
        code: 124,
        message: 'Invalid meeting ID',
      };

      const error = parseApiError(data);

      expect(error.code).toBe(124);
      expect(error.message).toBe('Invalid meeting ID');
    });

    it('should parse error with nested errors array', () => {
      const data = {
        code: 400,
        message: 'Validation error',
        errors: [
          { code: 4001, message: 'Invalid topic', field: 'topic' },
          { code: 4002, message: 'Invalid start_time', field: 'start_time' },
        ],
      };

      const error = parseApiError(data);

      expect(error.code).toBe(400);
      expect(error.errors).toHaveLength(2);
      expect(error.errors?.[0].field).toBe('topic');
    });

    it('should handle string error response', () => {
      const data = 'Internal server error';

      const error = parseApiError(data);

      expect(error.code).toBe(-1);
      expect(error.message).toBe('Internal server error');
    });

    it('should handle unknown error format', () => {
      const data = {};

      const error = parseApiError(data);

      expect(error.code).toBe(-1);
      expect(error.message).toBe('Unknown error');
    });
  });
});
