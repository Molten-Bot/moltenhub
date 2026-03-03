package api

import (
	"errors"
	"net/http"
	"strings"

	"statocyst/internal/auth"
	"statocyst/internal/store"
)

type registerRequest struct {
	AgentID string `json:"agent_id"`
}

type allowInboundRequest struct {
	FromAgentID string `json:"from_agent_id"`
}

func (h *Handler) handleRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w)
		return
	}

	var req registerRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", "invalid JSON request")
		return
	}

	req.AgentID = strings.TrimSpace(req.AgentID)
	if !validateAgentID(req.AgentID) {
		writeError(w, http.StatusBadRequest, "invalid_agent_id", "agent_id must match [A-Za-z0-9._:-]{1,128}")
		return
	}

	token, err := auth.GenerateToken()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "token_generation_failed", "failed to generate token")
		return
	}

	tokenHash := auth.HashToken(token)
	agent, err := h.store.RegisterAgent(req.AgentID, tokenHash, h.now().UTC())
	if err != nil {
		if errors.Is(err, store.ErrAgentExists) {
			writeError(w, http.StatusConflict, "agent_exists", "agent_id already registered")
			return
		}
		writeError(w, http.StatusInternalServerError, "store_error", "failed to register agent")
		return
	}

	writeJSON(w, http.StatusCreated, map[string]string{
		"agent_id": agent.AgentID,
		"token":    token,
	})
}

func (h *Handler) handleAgentSubroutes(w http.ResponseWriter, r *http.Request) {
	agentID, ok := parseAgentAllowInboundPath(r.URL.Path)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found", "route not found")
		return
	}

	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w)
		return
	}

	authenticatedAgentID, err := h.authenticateAgent(r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "unauthorized", "missing or invalid bearer token")
		return
	}

	if authenticatedAgentID != agentID {
		writeError(w, http.StatusForbidden, "token_agent_mismatch", "token does not match path agent_id")
		return
	}

	var req allowInboundRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", "invalid JSON request")
		return
	}

	req.FromAgentID = strings.TrimSpace(req.FromAgentID)
	if !validateAgentID(req.FromAgentID) {
		writeError(w, http.StatusBadRequest, "invalid_from_agent_id", "from_agent_id must match [A-Za-z0-9._:-]{1,128}")
		return
	}

	err = h.store.AddInboundAllow(agentID, req.FromAgentID)
	if err != nil {
		switch {
		case errors.Is(err, store.ErrSenderUnknown):
			writeError(w, http.StatusNotFound, "unknown_sender", "from_agent_id is not registered")
		case errors.Is(err, store.ErrAgentNotFound):
			writeError(w, http.StatusNotFound, "unknown_agent", "agent_id is not registered")
		default:
			writeError(w, http.StatusInternalServerError, "store_error", "failed to update inbound allowlist")
		}
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{
		"status":            "ok",
		"receiver_agent_id": agentID,
		"from_agent_id":     req.FromAgentID,
	})
}
