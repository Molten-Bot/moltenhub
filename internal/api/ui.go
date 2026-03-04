package api

import (
	_ "embed"
	"net/http"
	"strings"
)

//go:embed ui/index.html
var uiIndexHTML []byte

//go:embed ui/app.js
var uiAppJS []byte

//go:embed ui/login.html
var uiLoginHTML []byte

//go:embed ui/login.js
var uiLoginJS []byte

//go:embed ui/common.js
var uiCommonJS []byte

//go:embed ui/profile.html
var uiProfileHTML []byte

//go:embed ui/profile.js
var uiProfileJS []byte

//go:embed ui/organization.html
var uiOrganizationHTML []byte

//go:embed ui/organization.js
var uiOrganizationJS []byte

//go:embed ui/agents.html
var uiAgentsHTML []byte

//go:embed ui/agents.js
var uiAgentsJS []byte

func (h *Handler) handleUI(w http.ResponseWriter, r *http.Request) {
	if strings.HasPrefix(r.URL.Path, "/v1/") || strings.HasPrefix(r.URL.Path, "/health") || strings.HasPrefix(r.URL.Path, "/openapi") {
		writeError(w, http.StatusNotFound, "not_found", "route not found")
		return
	}

	switch r.URL.Path {
	case "/", "/index.html":
		if r.Method != http.MethodGet {
			writeMethodNotAllowed(w)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(uiLoginHTML)
		return
	case "/login.js":
		if r.Method != http.MethodGet {
			writeMethodNotAllowed(w)
			return
		}
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(uiLoginJS)
		return
	case "/common.js":
		if r.Method != http.MethodGet {
			writeMethodNotAllowed(w)
			return
		}
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(uiCommonJS)
		return
	case "/profile", "/profile/", "/profile/index.html":
		if r.Method != http.MethodGet {
			writeMethodNotAllowed(w)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(uiProfileHTML)
		return
	case "/profile.js":
		if r.Method != http.MethodGet {
			writeMethodNotAllowed(w)
			return
		}
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(uiProfileJS)
		return
	case "/organization", "/organization/", "/organization/index.html":
		if r.Method != http.MethodGet {
			writeMethodNotAllowed(w)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(uiOrganizationHTML)
		return
	case "/organization.js":
		if r.Method != http.MethodGet {
			writeMethodNotAllowed(w)
			return
		}
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(uiOrganizationJS)
		return
	case "/agents", "/agents/", "/agents/index.html":
		if r.Method != http.MethodGet {
			writeMethodNotAllowed(w)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(uiAgentsHTML)
		return
	case "/agents.js":
		if r.Method != http.MethodGet {
			writeMethodNotAllowed(w)
			return
		}
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(uiAgentsJS)
		return
	case "/domains", "/domains/", "/domains/index.html":
		if r.Method != http.MethodGet {
			writeMethodNotAllowed(w)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(uiIndexHTML)
		return
	case "/app.js", "/domains/app.js":
		if r.Method != http.MethodGet {
			writeMethodNotAllowed(w)
			return
		}
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(uiAppJS)
		return
	default:
		writeError(w, http.StatusNotFound, "not_found", "route not found")
		return
	}
}
