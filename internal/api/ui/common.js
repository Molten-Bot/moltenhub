const StatocystUI = (() => {
  const TOKEN_KEY = "statocyst_access_token";
  const DEV_ID_KEY = "statocyst_dev_human_id";
  const DEV_EMAIL_KEY = "statocyst_dev_human_email";

  const $ = (id) => document.getElementById(id);

  function readStorage(key) {
    return localStorage.getItem(key) || "";
  }

  function writeStorage(key, value) {
    if (!value) {
      localStorage.removeItem(key);
      return;
    }
    localStorage.setItem(key, value);
  }

  function getSession() {
    const tokenInput = $("authToken");
    const humanIDInput = $("humanId");
    const humanEmailInput = $("humanEmail");

    return {
      token: (tokenInput?.value || readStorage(TOKEN_KEY)).trim(),
      humanID: (humanIDInput?.value || readStorage(DEV_ID_KEY)).trim(),
      humanEmail: (humanEmailInput?.value || readStorage(DEV_EMAIL_KEY)).trim(),
    };
  }

  function saveSessionFromInputs() {
    const session = getSession();
    writeStorage(TOKEN_KEY, session.token);
    writeStorage(DEV_ID_KEY, session.humanID);
    writeStorage(DEV_EMAIL_KEY, session.humanEmail);
    return session;
  }

  function clearSession() {
    localStorage.removeItem(TOKEN_KEY);
    localStorage.removeItem(DEV_ID_KEY);
    localStorage.removeItem(DEV_EMAIL_KEY);
    if ($("authToken")) $("authToken").value = "";
    if ($("humanId")) $("humanId").value = "";
    if ($("humanEmail")) $("humanEmail").value = "";
  }

  function headers() {
    const session = getSession();
    const h = { "Content-Type": "application/json" };
    if (session.token) h.Authorization = `Bearer ${session.token}`;
    if (session.humanID) h["X-Human-Id"] = session.humanID;
    if (session.humanEmail) h["X-Human-Email"] = session.humanEmail;
    return h;
  }

  async function req(path, method = "GET", body = null) {
    const res = await fetch(path, {
      method,
      headers: headers(),
      body: body ? JSON.stringify(body) : null,
    });
    const text = await res.text();
    let data = text;
    try {
      data = JSON.parse(text || "{}");
    } catch (_) {}
    return { status: res.status, data };
  }

  function out(elID, payload) {
    const el = $(elID);
    if (!el) return;
    el.textContent = JSON.stringify(payload, null, 2);
  }

  function setSessionStatus(message, warn = false) {
    const el = $("sessionStatus");
    if (!el) return;
    el.textContent = message;
    el.className = warn ? "status warn" : "status";
  }

  async function loadConfig() {
    const r = await req("/v1/ui/config");
    if (r.status === 200) {
      return r.data;
    }
    return null;
  }

  async function initSessionPanel() {
    if ($("authToken")) $("authToken").value = readStorage(TOKEN_KEY);
    if ($("humanId")) $("humanId").value = readStorage(DEV_ID_KEY);
    if ($("humanEmail")) $("humanEmail").value = readStorage(DEV_EMAIL_KEY);

    if ($("btnSaveSession")) {
      $("btnSaveSession").onclick = () => {
        const session = saveSessionFromInputs();
        const mode = session.token ? "bearer token" : "dev headers";
        setSessionStatus(`Session saved (${mode}).`);
      };
    }

    if ($("btnClearSession")) {
      $("btnClearSession").onclick = () => {
        clearSession();
        setSessionStatus("Session cleared.");
      };
    }

    if ($("btnGoLogin")) {
      $("btnGoLogin").onclick = () => {
        window.location.assign("/");
      };
    }

    const cfg = await loadConfig();
    const summary = $("configSummary");
    if (!cfg) {
      if (summary) summary.textContent = "Auth provider config unavailable";
      setSessionStatus("Could not load /v1/ui/config", true);
      return null;
    }

    if (summary) {
      summary.textContent = `Auth provider: ${cfg.human_auth_provider || "unknown"}`;
    }

    const session = getSession();
    if (session.token) {
      setSessionStatus("Using saved bearer token.");
    } else if (session.humanID && session.humanEmail) {
      setSessionStatus("Using dev human headers.", cfg.human_auth_provider === "supabase");
    } else {
      setSessionStatus("No session set yet. Login on / or set dev headers here.", true);
    }

    return cfg;
  }

  async function populateOrgSelect(selectID, outputID = "") {
    const r = await req("/v1/me/orgs");
    if (outputID) out(outputID, r);

    const select = $(selectID);
    if (!select) return r;
    select.innerHTML = "";

    if (r.status !== 200 || !Array.isArray(r.data.memberships)) {
      return r;
    }

    for (const membership of r.data.memberships) {
      const opt = document.createElement("option");
      opt.value = membership.org.org_id;
      opt.textContent = `${membership.org.name} (${membership.membership.role})`;
      select.appendChild(opt);
    }

    return r;
  }

  function selectedOrg(selectID) {
    return ($(selectID)?.value || "").trim();
  }

  return {
    $,
    req,
    out,
    initSessionPanel,
    populateOrgSelect,
    selectedOrg,
    setSessionStatus,
    saveSessionFromInputs,
    clearSession,
  };
})();
