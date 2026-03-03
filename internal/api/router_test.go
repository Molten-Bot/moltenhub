package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"statocyst/internal/longpoll"
	"statocyst/internal/store"
)

func newTestRouter() http.Handler {
	st := store.NewMemoryStore()
	waiters := longpoll.NewWaiters()
	h := NewHandler(st, waiters)
	return NewRouter(h)
}

func registerAgent(t *testing.T, router http.Handler, agentID string) string {
	t.Helper()
	body := map[string]string{"agent_id": agentID}
	resp := doJSONRequest(t, router, http.MethodPost, "/v1/agents/register", "", body)
	if resp.Code != http.StatusCreated {
		t.Fatalf("register %s failed: status=%d body=%s", agentID, resp.Code, resp.Body.String())
	}
	var payload map[string]string
	if err := json.Unmarshal(resp.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode register response: %v", err)
	}
	token := payload["token"]
	if token == "" {
		t.Fatalf("register %s returned empty token", agentID)
	}
	return token
}

func allowInbound(t *testing.T, router http.Handler, receiverID, receiverToken, senderID string) *httptest.ResponseRecorder {
	t.Helper()
	path := fmt.Sprintf("/v1/agents/%s/allow-inbound", receiverID)
	body := map[string]string{"from_agent_id": senderID}
	return doJSONRequest(t, router, http.MethodPost, path, receiverToken, body)
}

func publishMessage(t *testing.T, router http.Handler, senderToken, receiverID, payload string) *httptest.ResponseRecorder {
	t.Helper()
	body := map[string]string{
		"to_agent_id":   receiverID,
		"content_type":  "text/plain",
		"payload":       payload,
		"client_msg_id": payload,
	}
	return doJSONRequest(t, router, http.MethodPost, "/v1/messages/publish", senderToken, body)
}

func pullMessage(t *testing.T, router http.Handler, token string, timeoutMS int) *httptest.ResponseRecorder {
	t.Helper()
	path := fmt.Sprintf("/v1/messages/pull?timeout_ms=%d", timeoutMS)
	req := httptest.NewRequest(http.MethodGet, path, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp := httptest.NewRecorder()
	router.ServeHTTP(resp, req)
	return resp
}

func doJSONRequest(t *testing.T, router http.Handler, method, path, token string, body any) *httptest.ResponseRecorder {
	t.Helper()

	var reqBody []byte
	if body != nil {
		var err error
		reqBody, err = json.Marshal(body)
		if err != nil {
			t.Fatalf("marshal request body: %v", err)
		}
	}

	req := httptest.NewRequest(method, path, bytes.NewReader(reqBody))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}

	resp := httptest.NewRecorder()
	router.ServeHTTP(resp, req)
	return resp
}

func decodePulledMessage(t *testing.T, body []byte) map[string]any {
	t.Helper()
	var wrapper map[string]map[string]any
	if err := json.Unmarshal(body, &wrapper); err != nil {
		t.Fatalf("decode pull response: %v body=%s", err, string(body))
	}
	msg, ok := wrapper["message"]
	if !ok {
		t.Fatalf("pull response missing message: %s", string(body))
	}
	return msg
}

func TestRegisterAndDuplicate(t *testing.T) {
	router := newTestRouter()

	token := registerAgent(t, router, "agent-a")
	if token == "" {
		t.Fatal("expected token on first registration")
	}

	resp := doJSONRequest(t, router, http.MethodPost, "/v1/agents/register", "", map[string]string{"agent_id": "agent-a"})
	if resp.Code != http.StatusConflict {
		t.Fatalf("expected 409 on duplicate registration, got %d: %s", resp.Code, resp.Body.String())
	}
}

func TestAllowInboundTokenMismatch(t *testing.T) {
	router := newTestRouter()
	tokenA := registerAgent(t, router, "agent-a")
	_ = registerAgent(t, router, "agent-b")

	resp := allowInbound(t, router, "agent-b", tokenA, "agent-a")
	if resp.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for token mismatch, got %d: %s", resp.Code, resp.Body.String())
	}
}

func TestAllowInboundUnknownSender(t *testing.T) {
	router := newTestRouter()
	tokenA := registerAgent(t, router, "agent-a")

	resp := allowInbound(t, router, "agent-a", tokenA, "ghost")
	if resp.Code != http.StatusNotFound {
		t.Fatalf("expected 404 for unknown sender, got %d: %s", resp.Code, resp.Body.String())
	}
}

func TestUnauthorizedPublishRejected(t *testing.T) {
	router := newTestRouter()
	tokenA := registerAgent(t, router, "agent-a")
	tokenB := registerAgent(t, router, "agent-b")
	tokenC := registerAgent(t, router, "agent-c")

	resp := allowInbound(t, router, "agent-b", tokenB, "agent-a")
	if resp.Code != http.StatusOK {
		t.Fatalf("allow-inbound setup failed: %d %s", resp.Code, resp.Body.String())
	}

	resp = publishMessage(t, router, tokenA, "agent-b", "hello")
	if resp.Code != http.StatusAccepted {
		t.Fatalf("expected 202 for allowed sender, got %d: %s", resp.Code, resp.Body.String())
	}

	resp = publishMessage(t, router, tokenC, "agent-b", "blocked")
	if resp.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for unauthorized sender, got %d: %s", resp.Code, resp.Body.String())
	}
}

func TestFIFOOrdering(t *testing.T) {
	router := newTestRouter()
	tokenA := registerAgent(t, router, "agent-a")
	tokenB := registerAgent(t, router, "agent-b")

	resp := allowInbound(t, router, "agent-b", tokenB, "agent-a")
	if resp.Code != http.StatusOK {
		t.Fatalf("allow-inbound failed: %d %s", resp.Code, resp.Body.String())
	}

	resp = publishMessage(t, router, tokenA, "agent-b", "first")
	if resp.Code != http.StatusAccepted {
		t.Fatalf("publish first failed: %d %s", resp.Code, resp.Body.String())
	}
	resp = publishMessage(t, router, tokenA, "agent-b", "second")
	if resp.Code != http.StatusAccepted {
		t.Fatalf("publish second failed: %d %s", resp.Code, resp.Body.String())
	}

	pull1 := pullMessage(t, router, tokenB, 10)
	if pull1.Code != http.StatusOK {
		t.Fatalf("pull first failed: %d %s", pull1.Code, pull1.Body.String())
	}
	msg1 := decodePulledMessage(t, pull1.Body.Bytes())
	if got := msg1["payload"]; got != "first" {
		t.Fatalf("expected first payload, got %v", got)
	}

	pull2 := pullMessage(t, router, tokenB, 10)
	if pull2.Code != http.StatusOK {
		t.Fatalf("pull second failed: %d %s", pull2.Code, pull2.Body.String())
	}
	msg2 := decodePulledMessage(t, pull2.Body.Bytes())
	if got := msg2["payload"]; got != "second" {
		t.Fatalf("expected second payload, got %v", got)
	}
}

func TestLongPollTimeout(t *testing.T) {
	router := newTestRouter()
	tokenA := registerAgent(t, router, "agent-a")

	start := time.Now()
	resp := pullMessage(t, router, tokenA, 25)
	if resp.Code != http.StatusNoContent {
		t.Fatalf("expected 204 on timeout, got %d: %s", resp.Code, resp.Body.String())
	}
	if time.Since(start) < 20*time.Millisecond {
		t.Fatalf("expected long-poll to wait before timeout")
	}
}

func TestConcurrentPublishPull(t *testing.T) {
	router := newTestRouter()
	tokenA := registerAgent(t, router, "agent-a")
	tokenB := registerAgent(t, router, "agent-b")

	resp := allowInbound(t, router, "agent-b", tokenB, "agent-a")
	if resp.Code != http.StatusOK {
		t.Fatalf("allow-inbound failed: %d %s", resp.Code, resp.Body.String())
	}

	const total = 40
	var pubWG sync.WaitGroup
	for i := 0; i < total; i++ {
		pubWG.Add(1)
		go func(i int) {
			defer pubWG.Done()
			payload := fmt.Sprintf("msg-%02d", i)
			resp := publishMessage(t, router, tokenA, "agent-b", payload)
				if resp.Code != http.StatusAccepted {
					t.Errorf("publish failed for %s: %d %s", payload, resp.Code, resp.Body.String())
					return
				}
			}(i)
	}
	pubWG.Wait()

	received := make(map[string]struct{})
	deadline := time.Now().Add(5 * time.Second)
	for len(received) < total && time.Now().Before(deadline) {
		resp := pullMessage(t, router, tokenB, 250)
		if resp.Code == http.StatusNoContent {
			continue
		}
		if resp.Code != http.StatusOK {
			t.Fatalf("pull failed: %d %s", resp.Code, resp.Body.String())
		}
		msg := decodePulledMessage(t, resp.Body.Bytes())
		payload, _ := msg["payload"].(string)
		received[payload] = struct{}{}
	}

	if len(received) != total {
		t.Fatalf("expected %d received messages, got %d", total, len(received))
	}
}
