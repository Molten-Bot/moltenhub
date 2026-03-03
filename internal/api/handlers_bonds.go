package api

import (
	"errors"
	"net/http"
	"strings"

	"statocyst/internal/store"
)

type createBondRequest struct {
	PeerAgentID string `json:"peer_agent_id"`
}

func (h *Handler) handleBonds(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w)
		return
	}

	callerAgentID, err := h.authenticateAgent(r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "unauthorized", "missing or invalid bearer token")
		return
	}

	var req createBondRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", "invalid JSON request")
		return
	}

	req.PeerAgentID = strings.TrimSpace(req.PeerAgentID)
	if !validateAgentID(req.PeerAgentID) {
		writeError(w, http.StatusBadRequest, "invalid_peer_agent_id", "peer_agent_id must match [A-Za-z0-9._:-]{1,128}")
		return
	}

	bondID, err := newUUIDv7()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "id_generation_failed", "failed to create bond_id")
		return
	}

	bond, created, err := h.store.CreateOrJoinBond(callerAgentID, req.PeerAgentID, bondID, h.now().UTC())
	if err != nil {
		switch {
		case errors.Is(err, store.ErrPeerUnknown):
			writeError(w, http.StatusNotFound, "unknown_peer", "peer_agent_id is not registered")
		case errors.Is(err, store.ErrSelfBond):
			writeError(w, http.StatusBadRequest, "invalid_peer_agent_id", "peer_agent_id cannot equal caller agent_id")
		case errors.Is(err, store.ErrAgentNotFound):
			writeError(w, http.StatusUnauthorized, "unauthorized", "missing or invalid bearer token")
		default:
			writeError(w, http.StatusInternalServerError, "store_error", "failed to create or join bond")
		}
		return
	}

	status := http.StatusOK
	if created {
		status = http.StatusCreated
	}
	writeJSON(w, status, map[string]any{
		"status":  "ok",
		"created": created,
		"bond":    bond,
	})
}

func (h *Handler) handleBondByID(w http.ResponseWriter, r *http.Request) {
	bondID, ok := parseBondIDPath(r.URL.Path)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found", "route not found")
		return
	}
	if r.Method != http.MethodDelete {
		writeMethodNotAllowed(w)
		return
	}

	callerAgentID, err := h.authenticateAgent(r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "unauthorized", "missing or invalid bearer token")
		return
	}

	err = h.store.DeleteBond(callerAgentID, bondID)
	if err != nil {
		switch {
		case errors.Is(err, store.ErrBondNotFound):
			writeError(w, http.StatusNotFound, "unknown_bond", "bond_id is not registered")
		case errors.Is(err, store.ErrBondAccessDenied):
			writeError(w, http.StatusForbidden, "bond_access_denied", "caller is not a participant in this bond")
		default:
			writeError(w, http.StatusInternalServerError, "store_error", "failed to delete bond")
		}
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{
		"status":  "ok",
		"bond_id": bondID,
		"result":  "deleted",
	})
}
