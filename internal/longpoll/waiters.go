package longpoll

import "sync"

type Waiters struct {
	mu      sync.Mutex
	byAgent map[string]map[chan struct{}]struct{}
}

func NewWaiters() *Waiters {
	return &Waiters{
		byAgent: make(map[string]map[chan struct{}]struct{}),
	}
}

func (w *Waiters) Register(agentID string) (<-chan struct{}, func()) {
	ch := make(chan struct{}, 1)

	w.mu.Lock()
	if _, ok := w.byAgent[agentID]; !ok {
		w.byAgent[agentID] = make(map[chan struct{}]struct{})
	}
	w.byAgent[agentID][ch] = struct{}{}
	w.mu.Unlock()

	cancel := func() {
		w.mu.Lock()
		defer w.mu.Unlock()
		waiters, ok := w.byAgent[agentID]
		if !ok {
			return
		}
		delete(waiters, ch)
		if len(waiters) == 0 {
			delete(w.byAgent, agentID)
		}
	}

	return ch, cancel
}

func (w *Waiters) Notify(agentID string) {
	w.mu.Lock()
	defer w.mu.Unlock()

	waiters := w.byAgent[agentID]
	for ch := range waiters {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}
