package store

import (
	"context"
	"encoding/xml"
	"io"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"statocyst/internal/model"
)

func TestS3QueueStore_EnqueueDequeueRoundTrip(t *testing.T) {
	type obj struct {
		key  string
		data []byte
	}
	var (
		mu    sync.Mutex
		store = make(map[string][]byte)
	)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := strings.TrimPrefix(r.URL.Path, "/")
		if strings.HasPrefix(path, "queue-bucket/") {
			key := strings.TrimPrefix(path, "queue-bucket/")
			switch r.Method {
			case http.MethodPut:
				body, _ := io.ReadAll(r.Body)
				mu.Lock()
				store[key] = body
				mu.Unlock()
				w.WriteHeader(http.StatusOK)
				return
			case http.MethodGet:
				mu.Lock()
				body, ok := store[key]
				mu.Unlock()
				if !ok {
					http.NotFound(w, r)
					return
				}
				w.WriteHeader(http.StatusOK)
				_, _ = w.Write(body)
				return
			case http.MethodDelete:
				mu.Lock()
				delete(store, key)
				mu.Unlock()
				w.WriteHeader(http.StatusNoContent)
				return
			}
		}

		if path == "queue-bucket" && r.Method == http.MethodGet && r.URL.Query().Get("list-type") == "2" {
			prefix := r.URL.Query().Get("prefix")
			mu.Lock()
			items := make([]obj, 0)
			for key, data := range store {
				if strings.HasPrefix(key, prefix) {
					items = append(items, obj{key: key, data: data})
				}
			}
			mu.Unlock()
			sort.Slice(items, func(i, j int) bool {
				return items[i].key < items[j].key
			})
			type content struct {
				Key string `xml:"Key"`
			}
			type listResult struct {
				XMLName  xml.Name  `xml:"ListBucketResult"`
				Contents []content `xml:"Contents"`
			}
			out := listResult{}
			if len(items) > 0 {
				out.Contents = append(out.Contents, content{Key: items[0].key})
			}
			w.WriteHeader(http.StatusOK)
			_ = xml.NewEncoder(w).Encode(out)
			return
		}

		http.NotFound(w, r)
	}))
	defer server.Close()

	q := &s3QueueStore{
		httpClient: server.Client(),
		endpoint:   server.URL,
		bucket:     "queue-bucket",
		region:     "us-east-1",
		prefix:     "statocyst-queue",
		pathStyle:  true,
	}

	msg := model.Message{
		MessageID:     "m-1",
		FromAgentUUID: "a-1",
		ToAgentUUID:   "b-1",
		FromAgentID:   "org-a/agent-a",
		ToAgentID:     "org-b/agent-b",
		SenderOrgID:   "org-a",
		ReceiverOrgID: "org-b",
		ContentType:   "text/plain",
		Payload:       "hello",
		CreatedAt:     time.Date(2026, 3, 5, 10, 0, 0, 0, time.UTC),
	}

	if err := q.Enqueue(context.Background(), msg); err != nil {
		t.Fatalf("enqueue failed: %v", err)
	}

	got, ok, err := q.Dequeue(context.Background(), "b-1")
	if err != nil {
		t.Fatalf("dequeue failed: %v", err)
	}
	if !ok {
		t.Fatalf("expected dequeued message")
	}
	if got.MessageID != msg.MessageID || got.Payload != msg.Payload || got.ToAgentUUID != msg.ToAgentUUID {
		t.Fatalf("unexpected dequeued message: %#v", got)
	}

	if _, ok, err := q.Dequeue(context.Background(), "b-1"); err != nil {
		t.Fatalf("second dequeue failed: %v", err)
	} else if ok {
		t.Fatalf("expected empty queue after first dequeue")
	}
}
