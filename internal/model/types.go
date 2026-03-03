package model

import "time"

// Agent is a registered identity and its server-side auth state.
type Agent struct {
	AgentID   string    `json:"agent_id"`
	TokenHash string    `json:"-"`
	CreatedAt time.Time `json:"created_at"`
}

// Message is a queued message envelope used by the local POC.
type Message struct {
	MessageID   string     `json:"message_id"`
	FromAgentID string     `json:"from_agent_id"`
	ToAgentID   string     `json:"to_agent_id"`
	ContentType string     `json:"content_type"`
	Payload     string     `json:"payload"`
	ClientMsgID *string    `json:"client_msg_id,omitempty"`
	CreatedAt   time.Time  `json:"created_at"`
}
