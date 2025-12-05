import dayjs from 'dayjs';
import { SessionRecord } from '../api';

interface Props {
  sessions: SessionRecord[];
}

const SessionTable = ({ sessions }: Props) => {
  if (!sessions.length) {
    return <p>No usage data for selected filter.</p>;
  }

  return (
    <div className="card">
      <h2>Container Sessions</h2>
      <div style={{ overflowX: 'auto' }}>
        <table className="table">
          <thead>
            <tr>
              <th>User ID</th>
              <th>Container</th>
              <th>Requested</th>
              <th>Status</th>
              <th>Start</th>
              <th>End</th>
              <th>Rate</th>
              <th>Notes</th>
            </tr>
          </thead>
          <tbody>
            {sessions.map((session) => (
              <tr key={session.id}>
                <td>{session.user_id}</td>
                <td>
                  <div style={{ fontWeight: 600 }}>{session.container_name}</div>
                  <small>{session.container_id}</small>
                </td>
                <td>
                  CPU: {session.requested_cpu}
                  <br />MEM: {session.requested_memory_mb}MB
                </td>
                <td>
                  <span className="badge">{session.status}</span>
                </td>
                <td>{dayjs(session.start_time).format('YYYY-MM-DD HH:mm')}</td>
                <td>{session.end_time ? dayjs(session.end_time).format('YYYY-MM-DD HH:mm') : '-'}</td>
                <td>${session.cost_rate_per_hour.toFixed(2)}/hr</td>
                <td>{session.notes || '-'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
};

export default SessionTable;
