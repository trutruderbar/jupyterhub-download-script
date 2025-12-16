(function () {
  const config = window.AppConfig || {};
  const loginConfig = window.LoginConfig || {};
  let getAuthToken = () => null;

  const PAGE_SIZES = {
    users: 8,
    sessions: 5,
    pods: 3,
  };

  const formatNumber = (value, digits = 1) => Number(value || 0).toFixed(digits);
  const formatMoney = (value) => `$${Number(value || 0).toFixed(2)}`;
  const toLocalDate = (value) => {
    if (!value) return null;
    if (value.endsWith('Z') || value.includes('+')) {
      return new Date(value);
    }
    return new Date(value.replace(' ', 'T'));
  };
  const formatDate = (value) => {
    const date = toLocalDate(value);
    return date ? date.toLocaleString('zh-TW', { hour12: false }) : '—';
  };
  const escapeAttr = (value) => String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');

  const fetchJSON = async (url, options = {}) => {
    const headers = { 'Content-Type': 'application/json', ...(options.headers || {}) };
    const userToken = getAuthToken();
    if (userToken) {
      headers.Authorization = `Bearer ${userToken}`;
    } else if (config.apiToken) {
      headers.Authorization = `Bearer ${config.apiToken}`;
    }
    if (config.apiToken) {
      headers['X-Dashboard-Token'] = config.apiToken;
    }
    const res = await fetch(url, { ...options, headers });
    if (!res.ok) {
      const text = await res.text().catch(() => '');
      throw new Error(text || res.statusText);
    }
    if (res.status === 204) return null;
    return res.json();
  };

  const App = {
    initialized: false,
    podInterval: null,
    state: {
      users: [],
      summary: [],
      sessions: [],
      pods: null,
      selectedUser: null,
      search: '',
      tab: 'usage',
      section: 'users',
      loadingCount: 0,
      pageUsers: 1,
      pageSessions: 1,
      pagePods: 1,
      limitDraft: null,
      limitSaving: false,
      limitStatus: null,
      limitInfo: null,
      limitActiveField: null,
      limitActiveCaret: null,
      machines: [],
      machinesLoaded: false,
      machinesLoading: false,
      machinesUpdatedAt: null,
      machineError: null,
      selectedPods: new Set(),
      podActionStatus: '',
      podActionKind: '',
      pvcs: [],
      pvcLoading: false,
      pvcStatus: '',
      pvcSearch: '',
    },
    init() {
      if (this.initialized) return;
      this.refs = {
        list: document.getElementById('user-list'),
        header: document.getElementById('user-header'),
        tabs: document.getElementById('main-tabs'),
        panes: document.querySelectorAll('[data-pane]'),
        sections: Array.from(document.querySelectorAll('[data-section]')),
        primaryTabs: document.getElementById('primary-tabs'),
        usageStats: document.getElementById('usage-stats'),
        usageTable: document.getElementById('usage-table'),
        podsSummary: document.getElementById('pods-summary'),
        podsList: document.getElementById('pods-list'),
        podDeleteButton: document.getElementById('pod-delete-selected'),
        podDeleteStatus: document.getElementById('pod-delete-status'),
        machineSummary: document.getElementById('machine-summary'),
        machineRows: document.getElementById('machine-rows'),
        search: document.getElementById('user-search'),
        userPagination: document.getElementById('user-pagination'),
        usagePagination: document.getElementById('usage-pagination'),
        podsPagination: document.getElementById('pods-pagination'),
        machineUpdated: document.getElementById('machine-updated'),
        machineAddForm: document.getElementById('machine-add-form'),
        machineAddLog: document.getElementById('machine-add-log'),
        machineDelForm: document.getElementById('machine-del-form'),
        machineDelLog: document.getElementById('machine-del-log'),
        machineRemoteToggle: document.getElementById('del-remote-toggle'),
        remoteFields: document.querySelector('[data-remote-area]'),
        globalRefresh: document.getElementById('global-refresh'),
        syncButton: document.getElementById('pod-sync-now'),
        syncStatus: document.getElementById('pod-sync-status'),
        pvcTable: document.getElementById('pvc-table'),
        pvcStatus: document.getElementById('pvc-status'),
        pvcRefresh: document.getElementById('pvc-refresh'),
        pvcCleanup: document.getElementById('pvc-cleanup'),
        pvcSearch: document.getElementById('pvc-search'),
      };

      this.limitStatusTimeout = null;
      this.limitInfoRequestId = 0;
      this.syncStatusTimeout = null;

      this.refs.tabs.addEventListener('click', (event) => {
        const tab = event.target.closest('.tab');
        if (!tab) return;
        this.setTab(tab.dataset.tab);
      });
      if (this.refs.primaryTabs) {
        this.refs.primaryTabs.addEventListener('click', (event) => {
          const tab = event.target.closest('.primary-tab');
          if (!tab) return;
          const section = tab.dataset.sectionButton || 'users';
          this.setSection(section);
        });
      }

      if (this.refs.search) {
        this.refs.search.addEventListener('input', (event) => {
          this.state.search = event.target.value.toLowerCase();
          this.state.pageUsers = 1;
          this.renderUserList();
        });
      }
      if (this.refs.globalRefresh) {
        this.refs.globalRefresh.addEventListener('click', () => this.handleGlobalRefresh());
      }
      if (this.refs.syncButton) {
        this.refs.syncButton.addEventListener('click', () => this.triggerPodReportSync());
      }
      if (this.refs.podDeleteButton && !this.refs.podDeleteButton.dataset.bound) {
        this.refs.podDeleteButton.addEventListener('click', () => this.deleteSelectedPods());
        this.refs.podDeleteButton.dataset.bound = '1';
      }
      if (this.refs.pvcRefresh && !this.refs.pvcRefresh.dataset.bound) {
        this.refs.pvcRefresh.addEventListener('click', () => this.loadPvcs());
        this.refs.pvcRefresh.dataset.bound = '1';
      }
      if (this.refs.pvcCleanup && !this.refs.pvcCleanup.dataset.bound) {
        this.refs.pvcCleanup.addEventListener('click', () => this.cleanupPvcs());
        this.refs.pvcCleanup.dataset.bound = '1';
      }
      if (this.refs.pvcSearch && !this.refs.pvcSearch.dataset.bound) {
        this.refs.pvcSearch.addEventListener('input', (event) => {
          this.state.pvcSearch = (event.target.value || '').toLowerCase();
          this.renderPvcs();
        });
        this.refs.pvcSearch.dataset.bound = '1';
      }
      this.bindMachineForms();
      this.initialized = true;
    },
    bindMachineForms() {
      if (!this.refs) return;
      const { machineAddForm, machineDelForm, machineRemoteToggle } = this.refs;
      if (machineAddForm && !machineAddForm.dataset.bound) {
        machineAddForm.addEventListener('submit', (event) => {
          event.preventDefault();
          this.submitMachineAdd();
        });
        machineAddForm.dataset.bound = '1';
      }
      if (machineDelForm && !machineDelForm.dataset.bound) {
        machineDelForm.addEventListener('submit', (event) => {
          event.preventDefault();
          this.submitMachineDelete();
        });
        machineDelForm.dataset.bound = '1';
      }
      if (machineRemoteToggle && !machineRemoteToggle.dataset.bound) {
        machineRemoteToggle.addEventListener('change', () => {
          this.toggleRemoteFields(machineRemoteToggle.checked);
        });
        machineRemoteToggle.dataset.bound = '1';
        this.toggleRemoteFields(machineRemoteToggle.checked);
      } else {
        this.toggleRemoteFields(false);
      }
    },
    toggleRemoteFields(enabled) {
      if (!this.refs || !this.refs.remoteFields) return;
      this.refs.remoteFields.hidden = !enabled;
    },
    clearPodSelection() {
      this.state.selectedPods = new Set();
      this.updatePodDeleteButton();
    },
    prunePodSelection(validSet) {
      const current = this.state.selectedPods || new Set();
      let changed = false;
      current.forEach((name) => {
        if (!validSet.has(name)) {
          current.delete(name);
          changed = true;
        }
      });
      if (changed) {
        this.updatePodDeleteButton();
      }
      this.state.selectedPods = current;
    },
    handlePodSelection(podName, checked) {
      if (!podName) return;
      const current = this.state.selectedPods || new Set();
      if (checked) {
        current.add(podName);
      } else {
        current.delete(podName);
      }
      this.state.selectedPods = current;
      this.updatePodDeleteButton();
      this.renderPods();
    },
    updatePodDeleteButton() {
      if (!this.refs || !this.refs.podDeleteButton) return;
      const hasSelection = (this.state.selectedPods && this.state.selectedPods.size > 0);
      this.refs.podDeleteButton.disabled = !hasSelection || this.state.podDeleting;
    },
    setPodDeletionStatus(message, kind = '') {
      if (!this.refs || !this.refs.podDeleteStatus) return;
      this.refs.podDeleteStatus.textContent = message || '';
      this.refs.podDeleteStatus.classList.remove('ok', 'err');
      if (kind) {
        this.refs.podDeleteStatus.classList.add(kind);
      }
    },
    async deleteSelectedPods() {
      const selected = Array.from(this.state.selectedPods || []);
      if (!selected.length || this.state.podDeleting) return;
      this.state.podDeleting = true;
      this.updatePodDeleteButton();
      this.setPodDeletionStatus('送出刪除請求中…', '');
      try {
        await Promise.all(selected.map((podName) => fetchJSON(`/api/pods/${encodeURIComponent(podName)}/action`, {
          method: 'POST',
          body: JSON.stringify({ action: 'delete' }),
        })));
        selected.forEach((pod) => this.state.selectedPods.delete(pod));
        this.setPodDeletionStatus('已送出刪除指令。', 'ok');
        this.updatePodDeleteButton();
        this.loadPods();
      } catch (err) {
        console.error(err);
        this.setPodDeletionStatus(err?.message || '刪除失敗，請稍後再試。', 'err');
        this.updatePodDeleteButton();
      } finally {
        this.state.podDeleting = false;
        this.updatePodDeleteButton();
      }
    },
    nodeUsageStats() {
      const usage = {};
      const pods = this.state.pods?.pods || [];
      pods.forEach((pod) => {
        if (!pod.node) return;
        const key = pod.node;
        const entry = usage[key] || {
          cpuMillicores: 0,
          memoryMiB: 0,
          gpu: 0,
          pods: 0,
        };
        entry.cpuMillicores += pod.requests?.cpuMillicores || 0;
        entry.memoryMiB += pod.requests?.memoryMiB || 0;
        entry.gpu += Number(pod.requests?.gpu || 0);
        entry.pods += 1;
        usage[key] = entry;
      });
      return usage;
    },
    setScriptLog(target, message, state = '') {
      if (!target) return;
      target.textContent = message || '';
      if (state) {
        target.dataset.state = state;
      } else {
        target.dataset.state = '';
      }
    },
    formatScriptResult(result) {
      if (!result) return '沒有輸出';
      const parts = [];
      if (result.stdout && result.stdout.trim()) {
        parts.push(result.stdout.trim());
      }
      if (result.stderr && result.stderr.trim()) {
        parts.push(`--- stderr ---\n${result.stderr.trim()}`);
      }
      if (typeof result.exit_code === 'number') {
        parts.push(`(exit code: ${result.exit_code})`);
      }
      if (result.hint) {
        parts.push(`提示：${result.hint}`);
      }
      return parts.filter(Boolean).join('\n') || '沒有輸出';
    },
    async runMachineCommand(url, payload, logTarget, button) {
      if (button) {
        button.disabled = true;
      }
      this.setScriptLog(logTarget, '執行中…', '');
      try {
        const result = await fetchJSON(url, {
          method: 'POST',
          body: JSON.stringify(payload),
        });
        const text = this.formatScriptResult(result);
        this.setScriptLog(logTarget, text, result.ok ? 'ok' : 'err');
        if (result.ok) {
          this.loadMachines();
        }
      } catch (err) {
        this.setScriptLog(logTarget, err?.message || '執行失敗', 'err');
      } finally {
        if (button) {
          button.disabled = false;
        }
      }
    },
    async submitMachineAdd() {
      if (!this.refs || !this.refs.machineAddForm) return;
      const form = this.refs.machineAddForm;
      const logTarget = this.refs.machineAddLog;
      const host = form.querySelector('[name="add-ip"]').value.trim();
      const user = form.querySelector('[name="add-user"]').value.trim() || 'root';
      const password = form.querySelector('[name="add-pass"]').value;
      const portRaw = form.querySelector('[name="add-port"]').value;
      const port = Number(portRaw) > 0 ? Number(portRaw) : 22;
      if (!host || !password) {
        this.setScriptLog(logTarget, '請輸入 Worker IP 與 SSH 密碼。', 'err');
        return;
      }
      const payload = {
        worker_ip: host,
        ssh_username: user,
        ssh_password: password,
        ssh_port: port,
      };
      const button = form.querySelector('button[type="submit"]');
      await this.runMachineCommand('/machines/add', payload, logTarget, button);
    },
    async submitMachineDelete() {
      if (!this.refs || !this.refs.machineDelForm) return;
      const form = this.refs.machineDelForm;
      const logTarget = this.refs.machineDelLog;
      const nodeName = form.querySelector('[name="del-node"]').value.trim();
      if (!nodeName) {
        this.setScriptLog(logTarget, '請輸入節點名稱。', 'err');
        return;
      }
      const payload = {
        node_name: nodeName,
        drain: form.querySelector('[name="del-drain"]')?.checked ?? true,
        force_remove: form.querySelector('[name="del-force"]')?.checked ?? false,
      };
      const remoteToggle = form.querySelector('[name="del-remote-toggle"]');
      if (remoteToggle && remoteToggle.checked) {
        const remoteHost = form.querySelector('[name="del-remote-ip"]').value.trim();
        const remoteUser = form.querySelector('[name="del-remote-user"]').value.trim() || 'root';
        const remotePass = form.querySelector('[name="del-remote-pass"]').value;
        const remotePortRaw = form.querySelector('[name="del-remote-port"]').value;
        const remotePort = Number(remotePortRaw) > 0 ? Number(remotePortRaw) : 22;
        if (!remoteHost || !remotePass) {
          this.setScriptLog(logTarget, '請輸入遠端清理所需的 IP 與密碼。', 'err');
          return;
        }
        payload.remote_cleanup = {
          worker_ip: remoteHost,
          ssh_username: remoteUser,
          ssh_password: remotePass,
          ssh_port: remotePort,
        };
      }
      const button = form.querySelector('button[type="submit"]');
      await this.runMachineCommand('/machines/delete', payload, logTarget, button);
    },
    start() {
      this.init();
      this.setSection(this.state.section || 'users');
      this.loadAll();
      this.startPolling();
    },
    handleGlobalRefresh() {
      return Promise.allSettled([this.loadAll(), this.loadMachines()]);
    },
    async triggerPodReportSync() {
      if (!this.refs || !this.refs.syncButton) return;
      const button = this.refs.syncButton;
      const status = this.refs.syncStatus;
      if (typeof window !== 'undefined' && this.syncStatusTimeout) {
        clearTimeout(this.syncStatusTimeout);
        this.syncStatusTimeout = null;
      }
      const original = button.textContent;
      button.disabled = true;
      button.textContent = '同步中...';
      if (status) {
        status.textContent = '同步中...';
      }
      try {
        const result = await fetchJSON('/api/pod-report-sync', { method: 'POST' });
        const written = Number(result?.records ?? result?.written ?? 0);
        if (status) {
          status.textContent = `同步完成（${written} 筆）`;
        }
        await this.handleGlobalRefresh();
      } catch (err) {
        console.error(err);
        if (status) {
          status.textContent = '同步失敗';
        }
        alert(`同步失敗：${err.message}`);
      } finally {
        button.disabled = false;
        button.textContent = original;
        if (status && typeof window !== 'undefined') {
          this.syncStatusTimeout = window.setTimeout(() => {
            if (this.refs && this.refs.syncStatus) {
              this.refs.syncStatus.textContent = '';
            }
          }, 6000);
        }
      }
    },
    startPolling() {
      if (this.podInterval) {
        clearInterval(this.podInterval);
      }
      this.podInterval = setInterval(() => this.loadPods(true), 20000);
    },
    stop() {
      if (this.podInterval) {
        clearInterval(this.podInterval);
        this.podInterval = null;
      }
      if (typeof window !== 'undefined' && this.syncStatusTimeout) {
        clearTimeout(this.syncStatusTimeout);
        this.syncStatusTimeout = null;
      }
      if (this.refs && this.refs.globalRefresh) {
        this.refs.globalRefresh.disabled = false;
        this.refs.globalRefresh.textContent = '重新整理';
      }
    },
    async loadAll() {
      this.setLoading(true);
      try {
        const [users, summary, sessions, pods] = await Promise.all([
          fetchJSON('/users'),
          fetchJSON('/billing/summary'),
          fetchJSON('/sessions'),
          fetchJSON('/api/usage'),
        ]);
        this.state.users = users;
        this.state.summary = summary;
        this.state.sessions = sessions.sort((a, b) => new Date(b.start_time) - new Date(a.start_time));
        this.state.pods = pods;
        const selectedExists = users.some((user) => user.id === this.state.selectedUser);
        if (!selectedExists) {
          this.state.selectedUser = users.length ? users[0].id : null;
        }
        this.state.limitInfo = null;
        this.syncLimitDraft(true);
        this.renderAll();
        if (this.state.selectedUser) {
          this.loadLimitInfo(this.state.selectedUser);
        }
      } catch (err) {
        console.error(err);
        alert(`無法載入資料：${err.message}`);
      } finally {
        this.setLoading(false);
      }
    },
    async loadPods(silent = false) {
      try {
        const pods = await fetchJSON('/api/usage');
        this.state.pods = pods;
        if (this.state.tab === 'pods') {
          this.renderPods();
        }
      } catch (err) {
        if (!silent) {
          console.error(err);
        }
      }
    },
    async loadMachines() {
      if (this.state.machinesLoading) {
        return;
      }
      this.state.machinesLoading = true;
      this.state.machineError = null;
      this.renderMachines();
      this.setLoading(true);
      try {
        const nodes = await fetchJSON('/machines');
        this.state.machines = Array.isArray(nodes) ? nodes : [];
        this.state.machinesLoaded = true;
        this.state.machinesUpdatedAt = new Date();
      } catch (err) {
        console.error(err);
        this.state.machineError = err?.message || '載入失敗';
        this.state.machinesLoaded = false;
      } finally {
        this.state.machinesLoading = false;
        this.setLoading(false);
        this.renderMachines();
      }
    },
    async loadPvcs(silent) {
      if (this.state.pvcLoading) return;
      this.state.pvcLoading = true;
      if (!silent) {
        this.state.pvcStatus = '載入 PVC 列表中...';
        this.renderPvcs();
      }
      try {
        const res = await fetchJSON('/pvcs');
        this.state.pvcs = (res && res.items) || [];
        if (!silent) {
          this.state.pvcStatus = `共 ${this.state.pvcs.length} 筆`;
        }
      } catch (err) {
        console.error(err);
        this.state.pvcStatus = err?.message || '載入 PVC 失敗';
      } finally {
        this.state.pvcLoading = false;
        this.renderPvcs();
      }
    },
    async cleanupPvcs() {
      if (this.state.pvcLoading) return;
      this.state.pvcStatus = '清理中 (閒置 >7 天)...';
      this.renderPvcs();
      try {
        const res = await fetchJSON('/pvcs/cleanup?threshold_days=7', { method: 'POST' });
        const deleted = (res && res.deleted) || [];
        const errors = (res && res.errors) || [];
        this.state.pvcStatus = `清理完成，刪除 ${deleted.length}，錯誤 ${errors.length}`;
      } catch (err) {
        console.error(err);
        this.state.pvcStatus = err?.message || '清理失敗';
      } finally {
        await this.loadPvcs(true);
        this.renderPvcs();
      }
    },
    async deletePvc(name) {
      if (!name) return;
      if (!window.confirm(`確認刪除 PVC：${name}？`)) return;
      this.state.pvcStatus = `刪除 ${name} 中...`;
      this.renderPvcs();
      try {
        await fetchJSON(`/pvcs/${encodeURIComponent(name)}`, { method: 'DELETE' });
        this.state.pvcStatus = `已刪除 ${name}`;
      } catch (err) {
        console.error(err);
        this.state.pvcStatus = err?.message || `刪除失敗：${name}`;
      } finally {
        await this.loadPvcs(true);
        this.renderPvcs();
      }
    },
    setLoading(isLoading) {
      if (!this.refs || !this.refs.globalRefresh) return;
      const current = this.state.loadingCount || 0;
      const next = Math.max(0, current + (isLoading ? 1 : -1));
      this.state.loadingCount = next;
      const disabled = next > 0;
      this.refs.globalRefresh.disabled = disabled;
      this.refs.globalRefresh.textContent = disabled ? '更新中…' : '重新整理';
    },
    setSection(sectionName) {
      const section = sectionName || 'users';
      this.state.section = section;
      if (this.refs.primaryTabs) {
        this.refs.primaryTabs.querySelectorAll('.primary-tab').forEach((tab) => {
          tab.classList.toggle('active', (tab.dataset.sectionButton || 'users') === section);
        });
      }
      if (this.refs.sections && this.refs.sections.forEach) {
        this.refs.sections.forEach((block) => {
          const match = (block.dataset.section || 'users') === section;
          if (match) {
            block.removeAttribute('hidden');
          } else {
            block.setAttribute('hidden', 'true');
          }
        });
      }
      if (section === 'machines') {
        if (!this.state.machinesLoaded && !this.state.machinesLoading) {
          this.loadMachines();
        } else {
          this.renderMachines();
        }
      }
      if (section === 'pvcs') {
        if (!this.state.pvcs.length) {
          this.loadPvcs();
        } else {
          this.renderPvcs();
        }
      }
    },
    setTab(tab) {
      this.state.tab = tab;
      this.refs.tabs.querySelectorAll('.tab').forEach((el) => {
        el.classList.toggle('active', el.dataset.tab === tab);
      });
      this.refs.panes.forEach((pane) => {
        pane.classList.toggle('active', pane.dataset.pane === tab);
      });
      if (tab === 'usage') {
        this.renderUsage();
      } else {
        this.renderPods();
      }
    },
    renderAll() {
      this.syncLimitDraft();
      this.renderUserList();
      this.renderHeader();
      this.renderUsage();
      this.renderPods();
    },
    renderUserList() {
      const { users, search, selectedUser } = this.state;
      if (!users.length) {
        this.refs.list.innerHTML = '<p class="muted">尚無使用者。</p>';
        return;
      }
      const filtered = users.filter((user) => {
        if (!search) return true;
        return `${user.full_name} ${user.username}`.toLowerCase().includes(search);
      });
      if (!filtered.length) {
        this.refs.list.innerHTML = '<p class="muted">找不到符合的使用者。</p>';
        return;
      }
      const usersPage = this.paginate(filtered, this.state.pageUsers, PAGE_SIZES.users);
      this.state.pageUsers = usersPage.page;
      this.refs.list.innerHTML = usersPage.items
        .map((user) => {
          const metrics = this.metricsForUser(user.id);
          const active = Number(selectedUser) === user.id;
          return `
            <div class="user-card ${active ? 'active' : ''}" data-user="${user.id}">
              <div>
                <strong>${user.full_name}</strong>
                <span class="muted">@${user.username}</span>
              </div>
              <div class="meta">
                <div>${metrics.sessions} Sessions</div>
                <div>${formatNumber(metrics.hours, 1)} hrs · ${formatMoney(metrics.cost)}</div>
              </div>
            </div>
          `;
        })
        .join('');
      this.refs.list.querySelectorAll('.user-card').forEach((card) => {
        card.addEventListener('click', () => {
          this.selectUser(Number(card.dataset.user));
        });
      });
      this.renderPager(this.refs.userPagination, usersPage.page, usersPage.totalPages, usersPage.totalItems, (page) => {
        this.state.pageUsers = page;
        this.renderUserList();
      });
    },
    renderHeader() {
      const user = this.selectedUser();
      if (!user) {
        this.refs.header.textContent = '請從左側選擇使用者以檢視使用紀錄與啟動中的 Pods。';
        return;
      }
      if (!this.state.limitDraft || this.state.limitDraft.userId !== user.id) {
        this.syncLimitDraft(true);
      }
      const draft = this.state.limitDraft || {};
      const status = this.state.limitStatus;
      const draftValid = this.limitDraftValid();
      const hasChanges = this.hasLimitChanges();
      const saveDisabled = this.state.limitSaving || !draftValid || !hasChanges;
      const limitInfo = this.state.limitInfo;
      let usageHtml = '';
      if (limitInfo && limitInfo.usage) {
        if (limitInfo.usage.available) {
          usageHtml = `
            <div class="limit-usage">
              <span>
                已使用 CPU ${formatNumber(limitInfo.usage.cpu_cores, 2)} / ${limitInfo.cpu_limit_cores} 核 ·
                記憶體 ${formatNumber(limitInfo.usage.memory_gib, 2)} / ${limitInfo.memory_limit_gib} GiB ·
                GPU ${formatNumber(limitInfo.usage.gpu, 2)} / ${limitInfo.gpu_limit}
              </span>
            </div>
          `;
        } else {
          usageHtml = '<div class="limit-usage muted">目前無法取得資源使用資訊。</div>';
        }
      } else {
        usageHtml = '<div class="limit-usage muted">資源使用資訊載入中…</div>';
      }
      this.refs.header.innerHTML = `
        <div class="user-header">
          <div class="user-info">
            <strong class="user-name">${user.full_name}</strong>
            <span class="muted">@${user.username}</span>
          </div>
          <form class="limit-form">
            <label>
              CPU 核心
              <input type="number" name="cpu_limit_cores" min="1" step="1" value="${escapeAttr(draft.cpu_limit_cores ?? '')}" />
            </label>
            <label>
              記憶體 (GiB)
              <input type="number" name="memory_limit_gib" min="1" step="1" value="${escapeAttr(draft.memory_limit_gib ?? '')}" />
            </label>
            <label>
              GPU 數量
              <input type="number" name="gpu_limit" min="0" step="1" value="${escapeAttr(draft.gpu_limit ?? '')}" />
            </label>
            <button type="submit" class="btn primary" ${saveDisabled ? 'disabled' : ''}>儲存</button>
          </form>
          ${status ? `<div class="limit-status ${status.type}">${status.text}</div>` : ''}
          ${usageHtml}
        </div>
      `;
      const form = this.refs.header.querySelector('.limit-form');
      if (form) {
        form.addEventListener('submit', (event) => {
          event.preventDefault();
          this.saveLimits();
        });
        form.querySelectorAll('input').forEach((input) => {
          input.addEventListener('input', (event) => {
            const { name, value } = event.target;
            this.state.limitActiveField = name;
            this.state.limitActiveCaret = event.target.selectionStart;
            this.state.limitDraft = {
              ...(this.state.limitDraft || {}),
              userId: user.id,
              [name]: value,
            };
            this.updateSaveButtonState();
          });
          input.addEventListener('focus', (event) => {
            this.state.limitActiveField = event.target.name;
            this.state.limitActiveCaret = event.target.selectionStart;
          });
        });
        const focusName = this.state.limitActiveField;
        if (focusName) {
          const focusInput = form.querySelector(`input[name="${focusName}"]`);
          if (focusInput) {
            focusInput.focus();
            let caret = this.state.limitActiveCaret;
            if (caret == null || Number.isNaN(caret)) {
              caret = focusInput.value.length;
            } else {
              caret = Math.max(0, Math.min(caret, focusInput.value.length));
            }
            if (typeof focusInput.setSelectionRange === 'function' && focusInput.type !== 'number') {
              focusInput.setSelectionRange(caret, caret);
            }
          }
        }
        this.updateSaveButtonState();
      }
    },
    renderUsage() {
      const user = this.selectedUser();
      if (!user) {
        this.refs.usageStats.innerHTML = '';
        this.refs.usageTable.innerHTML = '<p class="muted">尚未選擇使用者。</p>';
        return;
      }
      const sessions = this.sessionsForUser(user.id);
      const metrics = this.metricsForUser(user.id);
      this.refs.usageStats.innerHTML = [
        { label: 'Sessions', value: metrics.sessions },
        { label: '累積時數', value: `${formatNumber(metrics.hours, 2)} hr` },
        { label: '估計成本', value: formatMoney(metrics.cost) },
      ]
        .map(
          (card) => `
            <div class="stat">
              <span>${card.label}</span>
              <strong>${card.value}</strong>
            </div>
          `,
        )
        .join('');

      if (!sessions.length) {
        this.refs.usageTable.innerHTML = '<p class="muted">尚無 session 記錄。</p>';
        this.renderPager(this.refs.usagePagination, 1, 1, 0, () => {});
        return;
      }
      const sessionsPage = this.paginate(sessions, this.state.pageSessions, PAGE_SIZES.sessions);
      this.state.pageSessions = sessionsPage.page;
      const rows = sessionsPage.items
        .map((session) => {
          const stats = this.sessionStats(session);
          const badge = session.status === 'running'
            ? 'status-badge status-running'
            : session.status === 'completed'
              ? 'status-badge status-pending'
              : 'status-badge status-failed';
          return `
            <tr>
              <td>
                <strong>${session.container_name}</strong><br />
                <small>${session.container_id || '—'}</small>
              </td>
              <td>CPU ${session.requested_cpu} 核 / MEM ${session.requested_memory_mb} MB / GPU ${session.requested_gpu}</td>
              <td><span class="${badge}">${session.status}</span></td>
              <td>
                ${formatDate(session.start_time)}<br />
                ${session.end_time ? formatDate(session.end_time) : '進行中'}
              </td>
              <td>${formatMoney(stats.cost)}</td>
            </tr>
          `;
        })
        .join('');

      this.refs.usageTable.innerHTML = `
        <div class="table-scroll">
          <table class="table">
            <thead>
              <tr>
                <th>Container</th>
                <th>資源需求</th>
                <th>狀態</th>
                <th>起訖</th>
                <th>估計費用</th>
              </tr>
            </thead>
            <tbody>${rows}</tbody>
          </table>
        </div>
      `;
      this.renderPager(this.refs.usagePagination, sessionsPage.page, sessionsPage.totalPages, sessions.length, (page) => {
        this.state.pageSessions = page;
        this.renderUsage();
      });
    },
    renderPods() {
      const user = this.selectedUser();
      if (!user) {
        this.refs.podsSummary.innerHTML = '';
        this.refs.podsList.innerHTML = '<p class="muted">尚未選擇使用者。</p>';
        this.renderPager(this.refs.podsPagination, 1, 1, 0, () => {});
        this.clearPodSelection();
        return;
      }
      const podsData = this.state.pods?.pods || [];
      const userPods = podsData.filter((pod) => this.belongsToUser(pod, user));
      if (!userPods.length) {
        this.refs.podsSummary.innerHTML = '';
        this.refs.podsList.innerHTML = '<p class="muted">此使用者目前沒有啟動中的 Pod。</p>';
        this.renderPager(this.refs.podsPagination, 1, 1, 0, () => {});
        this.clearPodSelection();
        return;
      }
      const validSelection = new Set(userPods.map((pod) => pod.podName));
      this.prunePodSelection(validSelection);

      const totals = userPods.reduce(
        (acc, pod) => {
          acc.cpu += pod.requests.cpuMillicores || 0;
          acc.mem += pod.requests.memoryMiB || 0;
          acc.gpu += Number(pod.requests.gpu || 0);
          return acc;
        },
        { cpu: 0, mem: 0, gpu: 0 },
      );
      this.refs.podsSummary.innerHTML = [
        { label: 'Pods', value: userPods.length },
        { label: 'CPU 需求', value: `${formatNumber(totals.cpu / 1000, 2)} 核` },
        { label: '記憶體需求', value: `${formatNumber(totals.mem / 1024, 2)} GiB` },
        { label: 'GPU 需求', value: `${totals.gpu || 0}` },
      ]
        .map(
          (card) => `
            <div class="stat">
              <span>${card.label}</span>
              <strong>${card.value}</strong>
            </div>
          `,
        )
        .join('');

      const podsPage = this.paginate(userPods, this.state.pagePods, PAGE_SIZES.pods);
      this.state.pagePods = podsPage.page;

      this.refs.podsList.innerHTML = podsPage.items
        .map((pod) => {
          const badge = pod.phase === 'Running'
            ? 'status-badge status-running'
            : pod.phase === 'Pending'
              ? 'status-badge status-pending'
              : 'status-badge status-failed';
          const selected = this.state.selectedPods.has(pod.podName);
          const selectionText = selected ? '已選取，點擊可取消' : '點擊以選取';
          return `
            <div class="pod-card ${selected ? 'is-selected' : ''}" data-pod-card="${pod.podName}" tabindex="0" role="button" aria-pressed="${selected}">
              <div class="pod-select-indicator" aria-hidden="true"></div>
              <div class="pod-select-label">${selectionText}：<strong>${pod.podName}</strong></div>
              <div class="meta-grid">
                <div><span>容器模式</span><strong>${pod.serverName || '預設環境'}</strong></div>
                <div><span>狀態</span><strong><span class="${badge}">${pod.phase || 'Unknown'}</span></strong></div>
                <div><span>所在節點</span><strong>${pod.node || '—'}</strong></div>
                <div><span>映像</span><strong>${pod.image || '—'}</strong></div>
              </div>
              <div class="meta-grid">
                <div><span>CPU 需求</span><strong>${formatNumber((pod.requests.cpuMillicores || 0) / 1000, 2)} 核</strong></div>
                <div><span>記憶體需求</span><strong>${formatNumber((pod.requests.memoryMiB || 0) / 1024, 2)} GiB</strong></div>
                <div><span>GPU 需求</span><strong>${pod.requests.gpu || 0}</strong></div>
                <div><span>啟動時間</span><strong>${formatDate(pod.startTime)}</strong></div>
              </div>
            </div>
          `;
        })
        .join('');
      if (this.refs.podsList) {
        this.refs.podsList.querySelectorAll('[data-pod-card]').forEach((card) => {
          const podName = card.dataset.podCard;
          if (!podName) return;
          const toggleSelection = () => {
            const currentlySelected = this.state.selectedPods.has(podName);
            this.handlePodSelection(podName, !currentlySelected);
          };
          card.addEventListener('click', (event) => {
            event.preventDefault();
            toggleSelection();
          });
          card.addEventListener('keydown', (event) => {
            if (event.key === 'Enter' || event.key === ' ') {
              event.preventDefault();
              toggleSelection();
            }
          });
        });
      }
      this.updatePodDeleteButton();

      this.renderPager(this.refs.podsPagination, podsPage.page, podsPage.totalPages, userPods.length, (page) => {
        this.state.pagePods = page;
        this.renderPods();
      });
    },
    renderMachines() {
      if (!this.refs || !this.refs.machineRows) {
        return;
      }
      const { machineSummary, machineRows, machineUpdated } = this.refs;
      const {
        machines,
        machinesLoaded,
        machinesLoading,
        machineError,
        machinesUpdatedAt,
      } = this.state;
      const usageByNode = this.nodeUsageStats();
      if (machineUpdated) {
        let note = '尚未載入';
        if (machineError) {
          note = `錯誤：${machineError}`;
        } else if (machinesLoading && !machinesLoaded) {
          note = '載入中…';
        } else if (machinesUpdatedAt instanceof Date) {
          note = `最後更新：${machinesUpdatedAt.toLocaleString('zh-TW', { hour12: false })}`;
        }
        machineUpdated.textContent = note;
      }
      if (machineError) {
        machineRows.innerHTML = `<tr><td colspan="6" class="muted">${escapeAttr(machineError)}</td></tr>`;
        if (machineSummary) machineSummary.innerHTML = '';
        return;
      }
      if (machinesLoading && !machinesLoaded) {
        machineRows.innerHTML = '<tr><td colspan="6" class="muted">載入中…</td></tr>';
        if (machineSummary) machineSummary.innerHTML = '';
        return;
      }
      if (!machines || machines.length === 0) {
        machineRows.innerHTML = '<tr><td colspan="6" class="muted">尚無節點資料。</td></tr>';
        if (machineSummary) machineSummary.innerHTML = '';
        return;
      }
      const formatAlloc = (value, digits = 2) => formatNumber(value || 0, digits);
      const readyCount = machines.filter((node) => node.ready).length;
      const totalCpu = machines.reduce((acc, node) => acc + (node.allocatable_cpu || 0), 0);
      const totalMem = machines.reduce((acc, node) => acc + (node.allocatable_memory_gib || 0), 0);
      const totalGpu = machines.reduce((acc, node) => acc + (node.allocatable_gpu || 0), 0);
      const requestedCpu = Object.values(usageByNode).reduce((acc, entry) => acc + (entry.cpuMillicores || 0), 0) / 1000;
      const requestedMem = Object.values(usageByNode).reduce((acc, entry) => acc + (entry.memoryMiB || 0), 0) / 1024;
      const requestedGpu = Object.values(usageByNode).reduce((acc, entry) => acc + (entry.gpu || 0), 0);
      if (machineSummary) {
        machineSummary.innerHTML = [
          { label: 'Ready 節點', value: `${readyCount} / ${machines.length}` },
          { label: 'CPU 申請 / 總量', value: `${formatAlloc(requestedCpu, 1)} / ${formatAlloc(totalCpu, 1)} 核` },
          { label: '記憶體申請 / 總量', value: `${formatAlloc(requestedMem, 1)} / ${formatAlloc(totalMem, 1)} GiB` },
          { label: 'GPU 申請 / 總量', value: `${formatAlloc(requestedGpu, 0)} / ${formatAlloc(totalGpu, 0)} 顆` },
        ]
          .map(
            (card) => `
              <div class="stat">
                <span>${card.label}</span>
                <strong>${card.value}</strong>
              </div>
            `,
          )
          .join('');
      }
      machineRows.innerHTML = machines
        .map((node) => {
          const badge = node.ready ? 'status-badge status-running' : 'status-badge status-failed';
          const sys = [node.os_image, node.kernel_version].filter(Boolean).join(' · ') || '—';
          const roleLabel = node.roles || 'worker';
          const status = node.status || (node.ready ? 'Ready' : 'NotReady');
          const nodeUsage = usageByNode[node.name] || { cpuMillicores: 0, memoryMiB: 0, gpu: 0 };
          const usedCpu = (nodeUsage.cpuMillicores || 0) / 1000;
          const usedMem = (nodeUsage.memoryMiB || 0) / 1024;
          const usedGpu = nodeUsage.gpu || 0;
          const totalCpuNode = node.capacity_cpu || 0;
          const totalMemNode = node.capacity_memory_gib || 0;
          const totalGpuNode = node.capacity_gpu || 0;
          return `
            <tr>
              <td>
                <strong>${escapeAttr(node.name)}</strong><br />
                <span class="muted">${escapeAttr(roleLabel)}</span>
              </td>
              <td><span class="${badge}">${escapeAttr(status)}</span></td>
              <td>${formatAlloc(usedCpu, 2)} / ${formatAlloc(totalCpuNode, 2)}</td>
              <td>${formatAlloc(usedMem, 1)} / ${formatAlloc(totalMemNode, 1)}</td>
              <td>${formatAlloc(usedGpu, 0)} / ${formatAlloc(totalGpuNode, 0)}</td>
              <td>${escapeAttr(sys)}</td>
            </tr>
          `;
        })
        .join('');
    },
    renderPvcs() {
      if (!this.refs || !this.refs.pvcTable) return;
      if (this.refs.pvcStatus) {
        this.refs.pvcStatus.textContent = this.state.pvcStatus || '';
      }
      if (this.state.pvcLoading) {
        this.refs.pvcTable.innerHTML = '<tr><td colspan="7" class="muted">載入中…</td></tr>';
        return;
      }
      const search = (this.state.pvcSearch || '').trim().toLowerCase();
      const list = (this.state.pvcs || []).filter((pvc) => {
        if (!search) return true;
        const haystack = `${pvc.name || ''} ${pvc.storage_class || ''}`.toLowerCase();
        return haystack.includes(search);
      });
      if (!list.length) {
        this.refs.pvcTable.innerHTML = '<tr><td colspan="7" class="muted">沒有 singleuser PVC。</td></tr>';
        return;
      }
      this.refs.pvcTable.innerHTML = list
        .map((pvc) => {
          const age = typeof pvc.age_days === 'number' ? pvc.age_days.toFixed(2) : '—';
          const created = pvc.creation_timestamp ? formatDate(pvc.creation_timestamp) : '—';
          return `
            <tr>
              <td>${escapeAttr(pvc.name)}</td>
              <td>${escapeAttr(pvc.storage_class || '')}</td>
              <td>${escapeAttr(pvc.phase || '')}</td>
              <td>${escapeAttr(pvc.capacity || '')}</td>
              <td>${created}</td>
              <td>${age}</td>
              <td><button class="btn danger" data-delete-pvc="${escapeAttr(pvc.name)}">刪除</button></td>
            </tr>
          `;
        })
        .join('');
      this.refs.pvcTable.querySelectorAll('[data-delete-pvc]').forEach((btn) => {
        btn.addEventListener('click', () => {
          this.deletePvc(btn.dataset.deletePvc);
        });
      });
    },
    sessionsForUser(userId) {
      return this.state.sessions.filter((session) => session.user_id === userId);
    },
    metricsForUser(userId) {
      const summaryEntry = this.state.summary.find((row) => row.user_id === userId);
      if (summaryEntry) {
        return {
          sessions: summaryEntry.total_sessions || 0,
          hours: summaryEntry.total_hours || 0,
          cost: summaryEntry.total_estimated_cost || 0,
        };
      }
      const sessions = this.sessionsForUser(userId);
      return sessions.reduce(
        (acc, session) => {
          const stats = this.sessionStats(session);
          acc.sessions += 1;
          acc.hours += stats.durationHours;
          acc.cost += stats.cost;
          return acc;
        },
        { sessions: 0, hours: 0, cost: 0 },
      );
    },
    sessionStats(session) {
      const startDate = toLocalDate(session.start_time);
      if (!startDate) {
        return { durationHours: 0, cost: 0 };
      }
      const start = startDate.getTime();
      const isRunning = (session.status || '').toLowerCase() === 'running';
      const endDate = !isRunning && session.end_time ? toLocalDate(session.end_time) : new Date();
      const end = endDate ? endDate.getTime() : Date.now();
      const durationHours = Math.max(0, (end - start) / 3600000);
      const cost = durationHours * (session.cost_rate_per_hour || 0);
      return { durationHours, cost };
    },
    selectedUser() {
      return this.state.users.find((user) => user.id === this.state.selectedUser) || null;
    },
    belongsToUser(pod, user) {
      const normalized = (value) => (value || '').toLowerCase();
      const podUser = normalized(pod.user);
      return podUser === normalized(user.username) || normalized(pod.displayUser) === normalized(user.full_name);
    },
    paginate(items, currentPage, perPage) {
      const totalItems = items.length;
      const totalPages = totalItems ? Math.ceil(totalItems / perPage) : 1;
      const safePage = Math.min(Math.max(1, currentPage), Math.max(1, totalPages));
      const start = (safePage - 1) * perPage;
      return {
        items: items.slice(start, start + perPage),
        page: safePage,
        totalPages: totalPages,
        totalItems,
      };
    },
    renderPager(container, page, totalPages, totalItems, onChange) {
      if (!container) return;
      if (totalItems === 0 || totalPages <= 1) {
        container.innerHTML = '';
        return;
      }
      container.innerHTML = `
        <button ${page === 1 ? 'disabled' : ''} data-dir="prev">上一頁</button>
        <span class="info">第 ${page} / ${totalPages} 頁</span>
        <button ${page === totalPages ? 'disabled' : ''} data-dir="next">下一頁</button>
      `;
      container.querySelector('[data-dir=\"prev\"]').addEventListener('click', () => {
        if (page > 1) onChange(page - 1);
      });
      container.querySelector('[data-dir=\"next\"]').addEventListener('click', () => {
        if (page < totalPages) onChange(page + 1);
      });
    },
    selectUser(userId) {
      if (this.state.selectedUser === userId) {
        this.syncLimitDraft();
        if (userId) {
          this.loadLimitInfo(userId);
        }
        return;
      }
      this.state.selectedUser = userId;
      this.clearPodSelection();
      this.state.pageSessions = 1;
      this.state.pagePods = 1;
      this.state.limitActiveField = null;
      this.state.limitActiveCaret = null;
      this.state.limitInfo = null;
      this.syncLimitDraft(true);
      this.renderAll();
      if (userId) {
        this.loadLimitInfo(userId);
      }
    },
    async loadLimitInfo(userId) {
      const user = this.state.users.find((item) => item.id === userId);
      if (!user) {
        this.state.limitInfo = null;
        this.renderHeader();
        return;
      }
      this.state.limitInfo = null;
      this.renderHeader();
      this.limitInfoRequestId += 1;
      const requestId = this.limitInfoRequestId;
      try {
        const info = await fetchJSON(`/users/${encodeURIComponent(user.username)}/limits`);
        if (this.limitInfoRequestId !== requestId || this.state.selectedUser !== userId) {
          return;
        }
        this.state.limitInfo = info;
        this.renderHeader();
      } catch (err) {
        if (this.limitInfoRequestId !== requestId || this.state.selectedUser !== userId) {
          return;
        }
        console.error(err);
        this.state.limitInfo = {
          username: user.username,
          full_name: user.full_name,
          cpu_limit_cores: user.cpu_limit_cores,
          memory_limit_gib: user.memory_limit_gib,
          gpu_limit: user.gpu_limit,
          usage: { available: false, cpu_cores: 0, memory_gib: 0, gpu: 0 },
        };
        this.renderHeader();
      }
    },
    syncLimitDraft(force = false) {
      const user = this.selectedUser();
      if (!user) {
        this.state.limitDraft = null;
        if (force) {
          this.setLimitStatus(null);
        }
        return;
      }
      if (force || !this.state.limitDraft || this.state.limitDraft.userId !== user.id) {
        this.state.limitDraft = {
          userId: user.id,
          cpu_limit_cores: String(user.cpu_limit_cores ?? ''),
          memory_limit_gib: String(user.memory_limit_gib ?? ''),
          gpu_limit: String(user.gpu_limit ?? ''),
        };
        this.setLimitStatus(null);
      }
    },
    limitDraftValues() {
      const draft = this.state.limitDraft;
      if (!draft) return null;
      const parse = (raw) => {
        const value = Number(raw);
        return Number.isFinite(value) ? value : NaN;
      };
      return {
        cpu: parse(draft.cpu_limit_cores),
        memory: parse(draft.memory_limit_gib),
        gpu: parse(draft.gpu_limit),
      };
    },
    limitDraftValid() {
      const values = this.limitDraftValues();
      if (!values) return false;
      return values.cpu >= 1 && values.memory >= 1 && values.gpu >= 0
        && Number.isFinite(values.cpu) && Number.isFinite(values.memory) && Number.isFinite(values.gpu);
    },
    hasLimitChanges() {
      const user = this.selectedUser();
      const values = this.limitDraftValues();
      if (!user || !values) return false;
      return (
        Number(user.cpu_limit_cores || 0) !== values.cpu
        || Number(user.memory_limit_gib || 0) !== values.memory
        || Number(user.gpu_limit || 0) !== values.gpu
      );
    },
    updateSaveButtonState() {
      if (!this.refs || !this.refs.header) return;
      const form = this.refs.header.querySelector('.limit-form');
      if (!form) return;
      const button = form.querySelector('button[type="submit"]');
      if (!button) return;
      const disabled = this.state.limitSaving || !this.limitDraftValid() || !this.hasLimitChanges();
      button.disabled = disabled;
      button.setAttribute('aria-disabled', String(disabled));
    },
    setLimitStatus(status) {
      if (this.limitStatusTimeout) {
        clearTimeout(this.limitStatusTimeout);
        this.limitStatusTimeout = null;
      }
      this.state.limitStatus = status || null;
      if (status) {
        this.limitStatusTimeout = setTimeout(() => {
          this.state.limitStatus = null;
          this.limitStatusTimeout = null;
          this.renderHeader();
        }, 4000);
      }
    },
    async saveLimits() {
      const user = this.selectedUser();
      if (!user || !this.limitDraftValid()) {
        this.setLimitStatus({ type: 'error', text: '請輸入有效的資源限制。' });
        this.renderHeader();
        return;
      }
      const values = this.limitDraftValues();
      this.state.limitSaving = true;
      this.renderHeader();
      try {
        const updated = await fetchJSON(`/users/${encodeURIComponent(user.full_name)}`, {
          method: 'PATCH',
          body: JSON.stringify({
            cpu_limit_cores: values.cpu,
            memory_limit_gib: values.memory,
            gpu_limit: values.gpu,
          }),
        });
        this.state.users = this.state.users.map((item) => (item.id === updated.id ? updated : item));
        this.state.limitDraft = {
          userId: updated.id,
          cpu_limit_cores: String(updated.cpu_limit_cores ?? ''),
          memory_limit_gib: String(updated.memory_limit_gib ?? ''),
          gpu_limit: String(updated.gpu_limit ?? ''),
        };
        this.setLimitStatus({ type: 'success', text: '已更新資源限制。' });
        this.loadLimitInfo(updated.id);
      } catch (err) {
        console.error(err);
        this.setLimitStatus({ type: 'error', text: '更新失敗，請稍後再試。' });
      } finally {
        this.state.limitSaving = false;
        this.renderHeader();
      }
    },
  };

  const Auth = {
    state: {
      token: null,
      user: null,
    },
    init() {
      this.loginScreen = document.getElementById('login-screen');
      this.portalShell = document.getElementById('portal-shell');
      this.form = document.getElementById('login-form');
      this.accountInput = document.getElementById('login-account');
      this.passwordInput = document.getElementById('login-password');
      this.rememberInput = document.getElementById('login-remember');
      this.errorBox = document.getElementById('login-error');
      this.loginButton = document.getElementById('btn-login');
      this.spinner = document.getElementById('login-spinner');
      this.togglePw = document.getElementById('btn-toggle-password');
      this.capsHint = document.getElementById('caps-indicator');
      this.logoutButton = document.getElementById('btn-logout');
      this.userNameLabel = document.getElementById('portal-user-name');
      this.toast = document.getElementById('portal-toast');
      this.apiEndpoint = loginConfig.apiAuth || '/iam/command';
      this.keyPrefix = (loginConfig.rememberKey || 'usage_portal').replace(/[^a-z0-9_]/gi, '_');
      this.keys = {
        remember: `${this.keyPrefix}_remember`,
        account: `${this.keyPrefix}_last_account`,
        token: `${this.keyPrefix}_token`,
        user: `${this.keyPrefix}_user`,
      };
      this.form.addEventListener('submit', (event) => {
        event.preventDefault();
        if (!this.loginButton.disabled) {
          this.login();
        }
      });
      this.logoutButton.addEventListener('click', () => this.logout(false));
      this.accountInput.addEventListener('input', () => {
        this.validate();
        this.errorBox.textContent = '';
      });
      this.passwordInput.addEventListener('input', () => {
        this.validate();
        this.errorBox.textContent = '';
      });
      this.passwordInput.addEventListener('keydown', (event) => {
        const caps = event.getModifierState && event.getModifierState('CapsLock');
        this.capsHint.style.display = caps ? 'inline' : 'none';
      });
      this.passwordInput.addEventListener('keyup', (event) => {
        const caps = event.getModifierState && event.getModifierState('CapsLock');
        this.capsHint.style.display = caps ? 'inline' : 'none';
      });
      this.togglePw.addEventListener('click', () => {
        this.passwordInput.type = this.passwordInput.type === 'password' ? 'text' : 'password';
      });
      this.restore();
    },
    parseJwt(token) {
      try {
        const [, payload] = token.split('.');
        const json = atob(payload.replace(/-/g, '+').replace(/_/g, '/'));
        return JSON.parse(decodeURIComponent(escape(json)));
      } catch {
        return null;
      }
    },
    tokenValid(token) {
      if (!token) return false;
      const payload = this.parseJwt(token);
      if (!payload?.exp) return false;
      return payload.exp > Math.floor(Date.now() / 1000) + 30;
    },
    restore() {
      const remembered = localStorage.getItem(this.keys.remember) === '1';
      this.rememberInput.checked = remembered;
      if (remembered) {
        this.accountInput.value = localStorage.getItem(this.keys.account) || '';
      } else {
        this.accountInput.value = '';
        localStorage.removeItem(this.keys.account);
      }
      this.validate();
      const token = sessionStorage.getItem(this.keys.token) || localStorage.getItem(this.keys.token);
      const userRaw = sessionStorage.getItem(this.keys.user) || localStorage.getItem(this.keys.user);
      let user = null;
      try {
        user = userRaw ? JSON.parse(userRaw) : null;
      } catch {
        user = null;
      }
      if (token && this.tokenValid(token)) {
        this.state.token = token;
        this.state.user = user;
        this.showPortal();
      } else {
        this.clearStoredTokens();
        this.showLogin();
      }
    },
    validate() {
      const ok = this.accountInput.value.trim().length > 0 && this.passwordInput.value.length > 0;
      this.loginButton.disabled = !ok;
      this.loginButton.setAttribute('aria-disabled', String(!ok));
      return ok;
    },
    toastMessage(message, kind = '') {
      if (!this.toast) return;
      this.toast.textContent = message;
      this.toast.className = `toast ${kind}`.trim();
      this.toast.style.display = 'block';
      clearTimeout(this.toastTimer);
      this.toastTimer = setTimeout(() => {
        this.toast.style.display = 'none';
      }, 2500);
    },
    storageForRemember(remember) {
      return remember ? localStorage : sessionStorage;
    },
    otherStorage(remember) {
      return remember ? sessionStorage : localStorage;
    },
    clearStoredTokens() {
      [localStorage, sessionStorage].forEach((store) => {
        store.removeItem(this.keys.token);
        store.removeItem(this.keys.user);
      });
    },
    async login() {
      if (!this.validate()) return;
      const account = this.accountInput.value.trim();
      const password = this.passwordInput.value;
      const remember = this.rememberInput.checked;
      this.errorBox.textContent = '';
      this.loginButton.disabled = true;
      this.loginButton.setAttribute('aria-disabled', 'true');
      this.spinner.style.display = 'inline-block';
      const body = {
        action: 'admin_login',
        payload: { account, password },
      };
      try {
        const response = await fetch(this.apiEndpoint, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: 'Bearer EMPTY',
          },
          body: JSON.stringify(body),
        });
        const text = await response.text();
        const data = text ? JSON.parse(text) : {};
        if (!response.ok || !data?.token) {
          const detail = (typeof data?.detail === 'string') ? data.detail : '登入失敗';
          throw new Error(detail);
        }
        this.state.token = data.token;
        this.state.user = data.userInfo || { account };
        const storage = this.storageForRemember(remember);
        const other = this.otherStorage(remember);
        storage.setItem(this.keys.token, data.token);
        storage.setItem(this.keys.user, JSON.stringify(this.state.user));
        other.removeItem(this.keys.token);
        other.removeItem(this.keys.user);
        localStorage.setItem(this.keys.remember, remember ? '1' : '0');
        if (remember) {
          localStorage.setItem(this.keys.account, account);
        } else {
          localStorage.removeItem(this.keys.account);
        }
        this.scheduleExpiry(data.token);
        this.showPortal(true);
        this.toastMessage('登入成功', 'ok');
      } catch (error) {
        this.errorBox.textContent = error?.message || '登入失敗';
        this.toastMessage(this.errorBox.textContent, 'err');
      } finally {
        this.spinner.style.display = 'none';
        this.loginButton.disabled = !this.validate();
        this.loginButton.setAttribute('aria-disabled', String(this.loginButton.disabled));
      }
    },
    scheduleExpiry(token) {
      clearTimeout(this.expireTimer);
      const payload = this.parseJwt(token);
      if (!payload?.exp) return;
      const msLeft = payload.exp * 1000 - Date.now();
      if (msLeft > 0) {
        this.expireTimer = setTimeout(() => this.logout(true), Math.max(0, msLeft - 5000));
      }
    },
    formatUserName() {
      return this.state.user?.displayName || this.state.user?.account || 'Admin';
    },
    showPortal() {
      this.loginScreen.style.display = 'none';
      this.portalShell.hidden = false;
      if (this.userNameLabel) {
        this.userNameLabel.textContent = this.formatUserName();
      }
      App.start();
    },
    showLogin(message) {
      this.portalShell.hidden = true;
      this.loginScreen.style.display = 'grid';
      if (this.userNameLabel) {
        this.userNameLabel.textContent = '—';
      }
      if (message) {
        this.errorBox.textContent = message;
      }
      App.stop();
    },
    logout(silent) {
      this.clearStoredTokens();
      this.state.token = null;
      this.state.user = null;
      clearTimeout(this.expireTimer);
      this.showLogin();
      if (!silent) {
        this.toastMessage('已登出', 'ok');
      }
    },
    getToken() {
      return this.state.token;
    },
  };

  window.UsageAuth = Auth;
  getAuthToken = () => Auth.getToken();

  document.addEventListener('DOMContentLoaded', () => Auth.init());
})();
