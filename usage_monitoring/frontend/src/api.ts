import axios from 'axios';

const fallbackHost = typeof window !== 'undefined' ? window.location.hostname : 'localhost';
const defaultBaseUrl = `http://${fallbackHost}:29781`;

const api = axios.create({
  baseURL: import.meta.env.VITE_API_BASE_URL || defaultBaseUrl
});

export interface User {
  id: number;
  username: string;
  full_name: string;
  email: string;
  department?: string | null;
  created_at: string;
}

export interface SessionRecord {
  id: number;
  user_id: number;
  container_name: string;
  container_id?: string | null;
  requested_cpu: number;
  requested_memory_mb: number;
  requested_gpu: number;
  cost_rate_per_hour: number;
  status: string;
  start_time: string;
  end_time?: string | null;
  actual_cpu_hours: number;
  actual_memory_mb_hours: number;
  notes?: string | null;
}

export interface UsageSummary {
  user_id: number;
  username: string;
  full_name: string;
  total_sessions: number;
  total_hours: number;
  total_estimated_cost: number;
}

export interface PvcInfo {
  name: string;
  namespace: string;
  storage_class: string;
  volume_name?: string;
  phase: string;
  capacity?: string;
  creation_timestamp?: string;
  age_days?: number | null;
}

export const fetchUsers = () => api.get<User[]>('/users');
export const fetchSessions = (userId?: number) =>
  api.get<SessionRecord[]>('/sessions', { params: userId ? { user_id: userId } : {} });
export const fetchSummary = () => api.get<UsageSummary[]>('/billing/summary');
export const fetchPvcs = () => api.get<{ items: PvcInfo[] }>('/pvcs');
export const cleanupPvcs = (thresholdDays = 7) =>
  api.post('/pvcs/cleanup', null, { params: { threshold_days: thresholdDays } });
export const deletePvc = (name: string) => api.delete(`/pvcs/${encodeURIComponent(name)}`);

export default api;
