// In-memory storage for pairing sessions
const sessions = new Map();
// Session timeout: 5 minutes
const SESSION_TIMEOUT_MS = 5 * 60 * 1000;
export function createSession(sessionId, channelId) {
    const now = new Date();
    const session = {
        sessionId,
        channelId,
        status: 'pending',
        createdAt: now,
        expiresAt: new Date(now.getTime() + SESSION_TIMEOUT_MS),
        message: 'Initializing pairing...',
    };
    sessions.set(sessionId, session);
    // Auto-expire after timeout
    setTimeout(() => {
        const s = sessions.get(sessionId);
        if (s && s.status !== 'success') {
            s.status = 'expired';
            s.message = 'Pairing session expired';
        }
    }, SESSION_TIMEOUT_MS);
    return session;
}
export function getSession(sessionId) {
    return sessions.get(sessionId);
}
export function updateSession(sessionId, updates) {
    const session = sessions.get(sessionId);
    if (!session)
        return undefined;
    Object.assign(session, updates);
    return session;
}
export function deleteSession(sessionId) {
    return sessions.delete(sessionId);
}
export function getSessionByChannel(channelId) {
    for (const session of sessions.values()) {
        if (session.channelId === channelId && session.status !== 'expired' && session.status !== 'success') {
            return session;
        }
    }
    return undefined;
}
// For testing
export function clearAllSessions() {
    sessions.clear();
}
//# sourceMappingURL=session-manager.js.map