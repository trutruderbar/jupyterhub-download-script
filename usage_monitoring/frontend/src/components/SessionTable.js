import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
import dayjs from 'dayjs';
const SessionTable = ({ sessions }) => {
    if (!sessions.length) {
        return _jsx("p", { children: "No usage data for selected filter." });
    }
    return (_jsxs("div", { className: "card", children: [_jsx("h2", { children: "Container Sessions" }), _jsx("div", { style: { overflowX: 'auto' }, children: _jsxs("table", { className: "table", children: [_jsx("thead", { children: _jsxs("tr", { children: [_jsx("th", { children: "User ID" }), _jsx("th", { children: "Container" }), _jsx("th", { children: "Requested" }), _jsx("th", { children: "Status" }), _jsx("th", { children: "Start" }), _jsx("th", { children: "End" }), _jsx("th", { children: "Rate" }), _jsx("th", { children: "Notes" })] }) }), _jsx("tbody", { children: sessions.map((session) => (_jsxs("tr", { children: [_jsx("td", { children: session.user_id }), _jsxs("td", { children: [_jsx("div", { style: { fontWeight: 600 }, children: session.container_name }), _jsx("small", { children: session.container_id })] }), _jsxs("td", { children: ["CPU: ", session.requested_cpu, _jsx("br", {}), "MEM: ", session.requested_memory_mb, "MB"] }), _jsx("td", { children: _jsx("span", { className: "badge", children: session.status }) }), _jsx("td", { children: dayjs(session.start_time).format('YYYY-MM-DD HH:mm') }), _jsx("td", { children: session.end_time ? dayjs(session.end_time).format('YYYY-MM-DD HH:mm') : '-' }), _jsxs("td", { children: ["$", session.cost_rate_per_hour.toFixed(2), "/hr"] }), _jsx("td", { children: session.notes || '-' })] }, session.id))) })] }) })] }));
};
export default SessionTable;
