package store

import (
	"errors"
	"sync"
	"time"

	"statocyst/internal/model"
)

var (
	ErrAgentExists   = errors.New("agent already exists")
	ErrAgentNotFound = errors.New("agent not found")
	ErrSenderUnknown = errors.New("sender agent not found")
	ErrNotAllowed    = errors.New("sender not allowed by receiver")
	ErrInvalidToken  = errors.New("invalid token")
)

type MemoryStore struct {
	mu sync.RWMutex

	agents       map[string]model.Agent
	tokenIndex   map[string]string
	inboundAllow map[string]map[string]struct{}
	queues       map[string][]model.Message
}

func NewMemoryStore() *MemoryStore {
	return &MemoryStore{
		agents:       make(map[string]model.Agent),
		tokenIndex:   make(map[string]string),
		inboundAllow: make(map[string]map[string]struct{}),
		queues:       make(map[string][]model.Message),
	}
}

func (s *MemoryStore) RegisterAgent(agentID, tokenHash string, now time.Time) (model.Agent, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.agents[agentID]; exists {
		return model.Agent{}, ErrAgentExists
	}

	agent := model.Agent{
		AgentID:   agentID,
		TokenHash: tokenHash,
		CreatedAt: now,
	}
	s.agents[agentID] = agent
	s.tokenIndex[tokenHash] = agentID
	s.queues[agentID] = s.queues[agentID]

	return agent, nil
}

func (s *MemoryStore) AgentIDForTokenHash(tokenHash string) (string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	agentID, ok := s.tokenIndex[tokenHash]
	if !ok {
		return "", ErrInvalidToken
	}
	return agentID, nil
}

func (s *MemoryStore) AddInboundAllow(receiverAgentID, senderAgentID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, ok := s.agents[receiverAgentID]; !ok {
		return ErrAgentNotFound
	}
	if _, ok := s.agents[senderAgentID]; !ok {
		return ErrSenderUnknown
	}

	if _, ok := s.inboundAllow[receiverAgentID]; !ok {
		s.inboundAllow[receiverAgentID] = make(map[string]struct{})
	}
	s.inboundAllow[receiverAgentID][senderAgentID] = struct{}{}
	return nil
}

func (s *MemoryStore) CanPublish(senderAgentID, receiverAgentID string) error {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if _, ok := s.agents[receiverAgentID]; !ok {
		return ErrAgentNotFound
	}

	senders := s.inboundAllow[receiverAgentID]
	if _, allowed := senders[senderAgentID]; !allowed {
		return ErrNotAllowed
	}
	return nil
}

func (s *MemoryStore) Enqueue(message model.Message) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, ok := s.agents[message.ToAgentID]; !ok {
		return ErrAgentNotFound
	}

	s.queues[message.ToAgentID] = append(s.queues[message.ToAgentID], message)
	return nil
}

func (s *MemoryStore) PopNext(agentID string) (model.Message, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()

	queue := s.queues[agentID]
	if len(queue) == 0 {
		return model.Message{}, false
	}

	message := queue[0]
	s.queues[agentID] = queue[1:]
	return message, true
}
