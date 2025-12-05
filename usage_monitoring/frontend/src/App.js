import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
import { useEffect, useMemo, useState } from 'react';
import { fetchSessions, fetchSummary, fetchUsers } from './api';
import SessionTable from './components/SessionTable';
const App = () => {
    const [users, setUsers] = useState([]);
    const [selectedUser, setSelectedUser] = useState();
    const [sessions, setSessions] = useState([]);
    const [summary, setSummary] = useState([]);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState(null);
    const selectedUserDetail = useMemo(() => users.find((u) => u.id === selectedUser), [selectedUser, users]);
    const selectedUserSummary = useMemo(() => summary.find((entry) => entry.user_id === selectedUser), [selectedUser, summary]);
    useEffect(() => {
        const bootstrap = async () => {
            setLoading(true);
            try {
                const [usersRes, summaryRes] = await Promise.all([fetchUsers(), fetchSummary()]);
                setUsers(usersRes.data);
                setSummary(summaryRes.data);
            }
            catch (err) {
                console.error(err);
                setError('Unable to load reference data');
            }
            finally {
                setLoading(false);
            }
        };
        bootstrap();
    }, []);
    useEffect(() => {
        const loadSessions = async () => {
            try {
                const response = await fetchSessions(selectedUser);
                setSessions(response.data);
            }
            catch (err) {
                console.error(err);
                setError('Unable to load sessions');
            }
        };
        loadSessions();
    }, [selectedUser]);
    if (loading) {
        return (_jsx("div", { className: "app-shell", children: _jsx("p", { children: "Loading usage dashboard..." }) }));
    }
    if (error) {
        return (_jsx("div", { className: "app-shell", children: _jsx("p", { children: error }) }));
    }
    const totalCost = summary.reduce((acc, entry) => acc + entry.total_estimated_cost, 0);
    const totalHours = summary.reduce((acc, entry) => acc + entry.total_hours, 0);
    return (_jsxs("div", { className: "app-shell", children: [_jsxs("header", { children: [_jsx("h1", { children: "Usage Accounting Dashboard" }), _jsx("p", { children: "Monitor container usage records and estimated billing for each user." })] }), _jsxs("section", { className: "card summary-grid", children: [_jsxs("div", { className: "summary-card", children: [_jsx("span", { children: "Total Users" }), _jsx("strong", { children: users.length })] }), _jsxs("div", { className: "summary-card", children: [_jsx("span", { children: "Total Hours" }), _jsx("strong", { children: totalHours.toFixed(1) })] }), _jsxs("div", { className: "summary-card", children: [_jsx("span", { children: "Projected Cost" }), _jsxs("strong", { children: ["$", totalCost.toFixed(2)] })] })] }), _jsxs("section", { className: "card", children: [_jsxs("div", { style: { display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: '1rem' }, children: [_jsxs("div", { children: [_jsx("h2", { children: "User Summary" }), _jsx("p", { style: { margin: 0 }, children: "Choose a user to inspect their sessions." })] }), _jsxs("select", { className: "select-user", value: selectedUser ?? '', onChange: (event) => setSelectedUser(event.target.value ? Number(event.target.value) : undefined), children: [_jsx("option", { value: "", children: "All Users" }), summary.map((user) => (_jsxs("option", { value: user.user_id, children: [user.username, " \u00B7 ", user.total_hours.toFixed(1), " hrs"] }, user.user_id)))] })] }), _jsx("div", { style: { overflowX: 'auto', marginTop: '1rem' }, children: _jsxs("table", { className: "table", children: [_jsx("thead", { children: _jsxs("tr", { children: [_jsx("th", { children: "User" }), _jsx("th", { children: "Sessions" }), _jsx("th", { children: "Hours" }), _jsx("th", { children: "Est. Cost" })] }) }), _jsx("tbody", { children: summary.map((row) => (_jsxs("tr", { children: [_jsxs("td", { children: [_jsx("strong", { children: row.full_name }), _jsx("br", {}), "@", row.username] }), _jsx("td", { children: row.total_sessions }), _jsx("td", { children: row.total_hours.toFixed(2) }), _jsxs("td", { children: ["$", row.total_estimated_cost.toFixed(2)] })] }, row.user_id))) })] }) })] }), selectedUserDetail && selectedUserSummary && (_jsxs("section", { className: "card", children: [_jsx("h3", { children: selectedUserDetail.full_name }), _jsxs("p", { style: { marginTop: 0 }, children: ["@", selectedUserDetail.username, " \u00B7 ", selectedUserDetail.email, " \u00B7 ", selectedUserDetail.department || 'No dept'] }), _jsxs("div", { className: "summary-grid", children: [_jsxs("div", { className: "summary-card", children: [_jsx("span", { children: "Sessions" }), _jsx("strong", { children: selectedUserSummary.total_sessions })] }), _jsxs("div", { className: "summary-card", children: [_jsx("span", { children: "Hours" }), _jsx("strong", { children: selectedUserSummary.total_hours.toFixed(1) })] }), _jsxs("div", { className: "summary-card", children: [_jsx("span", { children: "Projected Cost" }), _jsxs("strong", { children: ["$", selectedUserSummary.total_estimated_cost.toFixed(2)] })] })] })] })), _jsx(SessionTable, { sessions: sessions })] }));
};
export default App;
