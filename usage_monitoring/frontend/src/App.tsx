import dayjs from 'dayjs';
import { useEffect, useMemo, useState } from 'react';
import {
  cleanupPvcs,
  deletePvc,
  fetchPvcs,
  fetchSessions,
  fetchSummary,
  fetchUsers,
  PvcInfo,
  SessionRecord,
  UsageSummary,
  User
} from './api';
import SessionTable from './components/SessionTable';

type TabKey = 'users' | 'pvcs' | 'machines' | 'help';

const tabs: { key: TabKey; label: string }[] = [
  { key: 'users', label: '用戶管理' },
  { key: 'pvcs', label: 'PVC管理' },
  { key: 'machines', label: '實體機管理' },
  { key: 'help', label: '使用說明' }
];

const App = () => {
  const [activeTab, setActiveTab] = useState<TabKey>('users');
  const [users, setUsers] = useState<User[]>([]);
  const [selectedUser, setSelectedUser] = useState<number | undefined>();
  const [sessions, setSessions] = useState<SessionRecord[]>([]);
  const [summary, setSummary] = useState<UsageSummary[]>([]);
  const [pvcs, setPvcs] = useState<PvcInfo[]>([]);
  const [loading, setLoading] = useState(true);
  const [pvcLoading, setPvcLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pvcMessage, setPvcMessage] = useState<string | null>(null);

  const selectedUserDetail = useMemo(() => users.find((u) => u.id === selectedUser), [selectedUser, users]);
  const selectedUserSummary = useMemo(
    () => summary.find((entry) => entry.user_id === selectedUser),
    [selectedUser, summary]
  );

  // Bootstrap user data
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

  // Load sessions for selected user
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
    if (activeTab === 'users') {
      loadSessions();
    }
  }, [selectedUser, activeTab]);

  // Load PVCs when tab activated
  useEffect(() => {
    const loadPvcs = async () => {
      setPvcLoading(true);
      setPvcMessage(null);
      try {
        const res = await fetchPvcs();
        setPvcs(res.data.items);
      } catch (err) {
        console.error(err);
        setError('Unable to load PVC list');
      } finally {
        setPvcLoading(false);
      }
    };
    if (activeTab === 'pvcs') {
      loadPvcs();
    }
  }, [activeTab]);

  const handleCleanupPvcs = async () => {
    setPvcMessage(null);
    setPvcLoading(true);
    try {
      const res = await cleanupPvcs(7);
      const deleted = (res.data.deleted || []) as string[];
      setPvcMessage(`清理完成，刪除 ${deleted.length} 個 PVC`);
      const refresh = await fetchPvcs();
      setPvcs(refresh.data.items);
    } catch (err) {
      console.error(err);
      setError('PVC 清理失敗');
    } finally {
      setPvcLoading(false);
    }
  };

  const handleDeletePvc = async (name: string) => {
    if (!window.confirm(`確認刪除 PVC：${name}？`)) return;
    setPvcLoading(true);
    setPvcMessage(null);
    try {
      await deletePvc(name);
      const refresh = await fetchPvcs();
      setPvcs(refresh.data.items);
      setPvcMessage(`已刪除 ${name}`);
    } catch (err) {
      console.error(err);
      setError(`刪除 PVC 失敗：${name}`);
    } finally {
      setPvcLoading(false);
    }
  };

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

  const renderUsersTab = () => (
    <>
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
        <div className="card-header-row">
          <div>
            <h2>使用者摘要</h2>
            <p style={{ margin: 0 }}>選擇使用者查看他的所有 session。</p>
          </div>
          <select
            className="select-user"
            value={selectedUser ?? ''}
            onChange={(event) => setSelectedUser(event.target.value ? Number(event.target.value) : undefined)}
          >
            <option value="">全部使用者</option>
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
    </>
  );

  const renderPvcsTab = () => (
    <section className="card">
      <div className="card-header-row">
        <div>
          <h2>PVC 管理</h2>
          <p style={{ margin: 0 }}>每天自動清理建立超過 7 天的 singleuser PVC，可手動立即執行或刪除特定 PVC。</p>
        </div>
        <div className="actions">
          <button className="btn secondary" onClick={async () => setPvcs((await fetchPvcs()).data.items)} disabled={pvcLoading}>
            重新整理
          </button>
          <button className="btn danger" onClick={handleCleanupPvcs} disabled={pvcLoading}>
            立即清理 >7 天
          </button>
        </div>
      </div>
      {pvcMessage && <div className="notice success">{pvcMessage}</div>}
      {pvcLoading ? (
        <p>載入 PVC 資訊中...</p>
      ) : (
        <div style={{ overflowX: 'auto', marginTop: '1rem' }}>
          <table className="table">
            <thead>
              <tr>
                <th>Name</th>
                <th>SC</th>
                <th>Phase</th>
                <th>Capacity</th>
                <th>Created</th>
                <th>Age (days)</th>
                <th>操作</th>
              </tr>
            </thead>
            <tbody>
              {pvcs.map((pvc) => (
                <tr key={pvc.name}>
                  <td>{pvc.name}</td>
                  <td>{pvc.storage_class || '-'}</td>
                  <td>{pvc.phase}</td>
                  <td>{pvc.capacity || '-'}</td>
                  <td>{pvc.creation_timestamp ? dayjs(pvc.creation_timestamp).format('YYYY-MM-DD HH:mm') : '-'}</td>
                  <td>{pvc.age_days !== null && pvc.age_days !== undefined ? pvc.age_days.toFixed(2) : '-'}</td>
                  <td>
                    <button className="btn link" onClick={() => handleDeletePvc(pvc.name)} disabled={pvcLoading}>
                      刪除
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );

  const renderMachinesTab = () => (
    <section className="card">
      <h2>實體機管理</h2>
      <p style={{ marginTop: 0 }}>
        本頁預留給節點/實體機監控與操作（例如 GPU/CPU 容量、可用度、污點/標籤狀態）。目前尚未串接資料來源，可依需要擴充。
      </p>
    </section>
  );

  const renderHelpTab = () => (
    <section className="card">
      <h2>使用說明</h2>
      <ul>
        <li>用戶管理：查看帳號、session 與累計資源用量與成本。</li>
        <li>PVC 管理：系統每日自動清理建立超過 7 天的 singleuser PVC；也可手動立即清理或刪除指定 PVC。</li>
        <li>實體機管理：預留區塊，可接入節點資源資訊與控制。</li>
        <li>API：/pvcs 取得列表，/pvcs/cleanup 立即清理（預設 7 天），/pvcs/&lt;name&gt; 刪除指定 PVC。</li>
      </ul>
    </section>
  );

  return (
    <div className="app-shell">
      <header className="topbar">
        <div>
          <h1 style={{ margin: 0 }}>Usage & Resource Portal</h1>
          <p style={{ margin: '4px 0 0' }}>JupyterHub 用戶、PVC 與資源管理</p>
        </div>
        <nav className="nav-tabs">
          {tabs.map((tab) => (
            <button
              key={tab.key}
              className={`tab ${activeTab === tab.key ? 'active' : ''}`}
              onClick={() => setActiveTab(tab.key)}
            >
              {tab.label}
            </button>
          ))}
        </nav>
      </header>

      {activeTab === 'users' && renderUsersTab()}
      {activeTab === 'pvcs' && renderPvcsTab()}
      {activeTab === 'machines' && renderMachinesTab()}
      {activeTab === 'help' && renderHelpTab()}
    </div>
  );
};

export default App;
