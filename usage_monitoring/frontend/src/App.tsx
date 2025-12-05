import { useEffect, useMemo, useState } from 'react';
import { fetchSessions, fetchSummary, fetchUsers, SessionRecord, UsageSummary, User } from './api';
import SessionTable from './components/SessionTable';

const App = () => {
  const [users, setUsers] = useState<User[]>([]);
  const [selectedUser, setSelectedUser] = useState<number | undefined>();
  const [sessions, setSessions] = useState<SessionRecord[]>([]);
  const [summary, setSummary] = useState<UsageSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const selectedUserDetail = useMemo(() => users.find((u) => u.id === selectedUser), [selectedUser, users]);
  const selectedUserSummary = useMemo(
    () => summary.find((entry) => entry.user_id === selectedUser),
    [selectedUser, summary]
  );

  useEffect(() => {
    const bootstrap = async () => {
      setLoading(true);
      try {
        const [usersRes, summaryRes] = await Promise.all([fetchUsers(), fetchSummary()]);
        setUsers(usersRes.data);
        setSummary(summaryRes.data);
      } catch (err) {
        console.error(err);
        setError('Unable to load reference data');
      } finally {
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
      } catch (err) {
        console.error(err);
        setError('Unable to load sessions');
      }
    };

    loadSessions();
  }, [selectedUser]);

  if (loading) {
    return (
      <div className="app-shell">
        <p>Loading usage dashboard...</p>
      </div>
    );
  }

  if (error) {
    return (
      <div className="app-shell">
        <p>{error}</p>
      </div>
    );
  }

  const totalCost = summary.reduce((acc, entry) => acc + entry.total_estimated_cost, 0);
  const totalHours = summary.reduce((acc, entry) => acc + entry.total_hours, 0);

  return (
    <div className="app-shell">
      <header>
        <h1>Usage Accounting Dashboard</h1>
        <p>Monitor container usage records and estimated billing for each user.</p>
      </header>

      <section className="card summary-grid">
        <div className="summary-card">
          <span>Total Users</span>
          <strong>{users.length}</strong>
        </div>
        <div className="summary-card">
          <span>Total Hours</span>
          <strong>{totalHours.toFixed(1)}</strong>
        </div>
        <div className="summary-card">
          <span>Projected Cost</span>
          <strong>${totalCost.toFixed(2)}</strong>
        </div>
      </section>

      <section className="card">
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: '1rem' }}>
          <div>
            <h2>User Summary</h2>
            <p style={{ margin: 0 }}>Choose a user to inspect their sessions.</p>
          </div>
          <select className="select-user" value={selectedUser ?? ''} onChange={(event) => setSelectedUser(event.target.value ? Number(event.target.value) : undefined)}>
            <option value="">All Users</option>
            {summary.map((user) => (
              <option key={user.user_id} value={user.user_id}>
                {user.username} · {user.total_hours.toFixed(1)} hrs
              </option>
            ))}
          </select>
        </div>
        <div style={{ overflowX: 'auto', marginTop: '1rem' }}>
          <table className="table">
            <thead>
              <tr>
                <th>User</th>
                <th>Sessions</th>
                <th>Hours</th>
                <th>Est. Cost</th>
              </tr>
            </thead>
            <tbody>
              {summary.map((row) => (
                <tr key={row.user_id}>
                  <td>
                    <strong>{row.full_name}</strong>
                    <br />@{row.username}
                  </td>
                  <td>{row.total_sessions}</td>
                  <td>{row.total_hours.toFixed(2)}</td>
                  <td>${row.total_estimated_cost.toFixed(2)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      {selectedUserDetail && selectedUserSummary && (
        <section className="card">
          <h3>{selectedUserDetail.full_name}</h3>
          <p style={{ marginTop: 0 }}>
            @{selectedUserDetail.username} · {selectedUserDetail.email} · {selectedUserDetail.department || 'No dept'}
          </p>
          <div className="summary-grid">
            <div className="summary-card">
              <span>Sessions</span>
              <strong>{selectedUserSummary.total_sessions}</strong>
            </div>
            <div className="summary-card">
              <span>Hours</span>
              <strong>{selectedUserSummary.total_hours.toFixed(1)}</strong>
            </div>
            <div className="summary-card">
              <span>Projected Cost</span>
              <strong>${selectedUserSummary.total_estimated_cost.toFixed(2)}</strong>
            </div>
          </div>
        </section>
      )}

      <SessionTable sessions={sessions} />
    </div>
  );
};

export default App;
