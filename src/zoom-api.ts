/**
 * Zoom API Models and Endpoints
 * 
 * Discovered through network sniffing.
 * Documents actual request/response structures.
 */

export interface ZoomMeeting {
  id: string;
  uuid: string;
  topic: string;
  type: number; // 1=instant, 2=scheduled, 3=recurring
  start_time: string; // ISO 8601
  duration: number; // minutes
  timezone: string;
  created_at: string;
  join_url: string;
  status: 'waiting' | 'started' | 'ended';
  host_id: string;
  host_email: string;
}

export interface ZoomMeetingDetail extends ZoomMeeting {
  agenda?: string;
  meeting_invitees?: ZoomMeetingInvitee[];
  settings?: ZoomMeetingSettings;
}

export interface ZoomMeetingInvitee {
  id: string;
  email: string;
  first_name?: string;
  last_name?: string;
  response_status: 'accepted' | 'declined' | 'waiting';
}

export interface ZoomMeetingSettings {
  host_video: boolean;
  participant_video: boolean;
  cn_meeting: boolean;
  in_meeting: boolean;
  join_before_host: boolean;
  mute_upon_entry: boolean;
  watermark: boolean;
  use_pmi: boolean;
  approval_type: number; // 0=automatic, 1=manual, 2=no registration
  audio: 'both' | 'telephony' | 'voip'; // Audio types
  alternative_hosts?: string;
  close_registration: boolean;
  waiting_room: boolean;
  global_dial_in_countries?: string[];
  contact_name?: string;
  contact_email?: string;
  registrants_confirmation_email: boolean;
  registrants_email_notification: boolean;
  meeting_authentication: boolean;
  encryption_type: 'best_available' | 'led' | 'e2ee';
  authentication_option?: string;
  authentication_domains?: string;
  authentication_name?: string;
  breakout_room?: {
    enable: boolean;
    rooms?: Array<{
      name: string;
      participants: string[];
    }>;
  };
  focus_mode: boolean;
  breakout_room_settings?: {
    enable: boolean;
    automatic_create_breakout_rooms: boolean;
    automatic_assign_to_breakout_rooms: boolean;
    unassigned_members_join_parent_meeting: boolean;
    breakout_rooms: Array<{
      name: string;
      participants: string[];
    }>;
  };
}

export interface CreateMeetingRequest {
  topic: string;
  type?: number; // default 2 (scheduled)
  start_time?: string; // ISO 8601, required if type=2
  duration?: number; // minutes, default 60
  timezone?: string;
  agenda?: string;
  settings?: Partial<ZoomMeetingSettings>;
  recurrence?: {
    type: number; // 1=daily, 2=weekly, 3=monthly
    repeat_interval: number;
    weekly_days?: string; // comma-separated: SU,MO,TU,WE,TH,FR,SA
    monthly_day?: number;
    monthly_week?: number; // -1=last, 1=first, etc.
    monthly_week_day?: number; // 1=Sunday...7=Saturday
    end_times?: number; // 0=never, 1=until end_date_time
    end_date_time?: string; // ISO 8601
  };
}

export interface ListMeetingsRequest {
  page_size?: number;
  page_number?: number;
  type?: 'scheduled' | 'live' | 'upcoming' | 'upcoming_meetings';
  from?: string; // ISO 8601
  to?: string; // ISO 8601
}

export interface ListMeetingsResponse {
  from: string;
  to: string;
  page_count: number;
  page_number: number;
  page_size: number;
  total_records: number;
  meetings: ZoomMeeting[];
}

/**
 * Zoom API Error Response
 */
export interface ZoomApiError {
  code: number;
  message: string;
  errors?: Array<{
    code: number;
    message: string;
    field?: string;
  }>;
}

/**
 * Validate that a created meeting object has required fields
 */
export function validateMeeting(meeting: any): meeting is ZoomMeeting {
  return (
    meeting.id !== undefined &&
    meeting.topic !== undefined &&
    meeting.start_time !== undefined
  );
}

/**
 * Validate CreateMeetingRequest
 */
export function validateCreateMeetingRequest(req: any): req is CreateMeetingRequest {
  if (!req.topic) return false;
  
  // Type 2 (scheduled) requires start_time
  if (req.type === 2 && !req.start_time) return false;
  
  return true;
}

/**
 * Parse API error response
 */
export function parseApiError(data: any): ZoomApiError {
  if (typeof data === 'string') {
    return {
      code: -1,
      message: data,
    };
  }

  if (data.code !== undefined) {
    return data;
  }

  return {
    code: -1,
    message: 'Unknown error',
  };
}
