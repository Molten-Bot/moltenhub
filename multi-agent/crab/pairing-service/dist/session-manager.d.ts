import type { PairingSession, ChannelId } from './types.js';
export declare function createSession(sessionId: string, channelId: ChannelId): PairingSession;
export declare function getSession(sessionId: string): PairingSession | undefined;
export declare function updateSession(sessionId: string, updates: Partial<Pick<PairingSession, 'status' | 'qrCodeData' | 'qrCodeRaw' | 'error' | 'message'>>): PairingSession | undefined;
export declare function deleteSession(sessionId: string): boolean;
export declare function getSessionByChannel(channelId: ChannelId): PairingSession | undefined;
export declare function clearAllSessions(): void;
//# sourceMappingURL=session-manager.d.ts.map