import axios from 'axios';
const fallbackHost = typeof window !== 'undefined' ? window.location.hostname : 'localhost';
const defaultBaseUrl = `http://${fallbackHost}:29781`;
const api = axios.create({
    baseURL: import.meta.env.VITE_API_BASE_URL || defaultBaseUrl
});
export const fetchUsers = () => api.get('/users');
export const fetchSessions = (userId) => api.get('/sessions', { params: userId ? { user_id: userId } : {} });
export const fetchSummary = () => api.get('/billing/summary');
export default api;
