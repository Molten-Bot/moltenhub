export type ChannelId = 'whatsapp' | 'signal';

export type PairingStatus = 'pending' | 'qr_ready' | 'scanning' | 'success' | 'error' | 'expired';

export interface PairingSession {
  sessionId: string;
  channelId: ChannelId;
  status: PairingStatus;
  qrCodeData?: string;          // Base64 data URL of QR code image
  qrCodeRaw?: string;           // Raw QR code string (for debugging)
  createdAt: Date;
  expiresAt: Date;
  error?: string;
  message?: string;
}

export interface StartPairingRequest {
  sessionId: string;
}

export interface PairingStatusResponse {
  sessionId: string;
  channelId: ChannelId;
  status: PairingStatus;
  qrCodeData?: string;
  expiresAt: string;
  error?: string;
  message?: string;
}

