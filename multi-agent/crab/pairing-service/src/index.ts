import express, { Request, Response, NextFunction } from 'express';
import { createSession, getSession, getSessionByChannel } from './session-manager.js';
import { startWhatsAppPairing } from './channels/whatsapp.js';
import { startSignalPairing } from './channels/signal.js';
import type { ChannelId, StartPairingRequest, PairingStatusResponse } from './types.js';

const app = express();
const PORT = parseInt(process.env.PAIRING_SERVICE_PORT || '18791', 10);

app.use(express.json());

// Request logging middleware
app.use((req: Request, _res: Response, next: NextFunction) => {
  console.log(`[pairing-service] ${req.method} ${req.path}`);
  next();
});

// Health check
app.get('/health', (_req: Request, res: Response) => {
  res.json({ status: 'ok', service: 'pairing-service' });
});

// POST /api/pairing/:channelId - Start pairing for a channel
app.post('/api/pairing/:channelId', async (req: Request, res: Response) => {
  const { channelId } = req.params;
  const { sessionId } = req.body as StartPairingRequest;

  // Validate channel
  if (channelId !== 'whatsapp' && channelId !== 'signal') {
    res.status(400).json({ error: `Invalid channel: ${channelId}` });
    return;
  }

  if (!sessionId) {
    res.status(400).json({ error: 'sessionId is required' });
    return;
  }

  console.log(`[pairing-service] Starting ${channelId} pairing for session: ${sessionId}`);

  // Check if there's already an active session for this channel
  const existingSession = getSessionByChannel(channelId as ChannelId);
  if (existingSession && existingSession.sessionId !== sessionId) {
    // Return existing session info
    res.json({
      success: true,
      sessionId: existingSession.sessionId,
      message: 'Using existing pairing session',
    });
    return;
  }

  // Create or get session
  let session = getSession(sessionId);
  if (!session) {
    session = createSession(sessionId, channelId as ChannelId);
  }

  // Start the pairing process asynchronously
  if (channelId === 'whatsapp') {
    startWhatsAppPairing(session).catch(err => {
      console.error('[pairing-service] WhatsApp pairing error:', err);
    });
  } else if (channelId === 'signal') {
    startSignalPairing(session).catch(err => {
      console.error('[pairing-service] Signal pairing error:', err);
    });
  }

  res.json({
    success: true,
    sessionId: session.sessionId,
    message: 'Pairing initiated',
  });
});

// GET /api/pairing/:sessionId - Get pairing status
app.get('/api/pairing/:sessionId', (req: Request, res: Response) => {
  const { sessionId } = req.params;

  const session = getSession(sessionId);
  if (!session) {
    res.status(404).json({ error: 'Session not found' });
    return;
  }

  const response: PairingStatusResponse = {
    sessionId: session.sessionId,
    channelId: session.channelId,
    status: session.status,
    qrCodeData: session.qrCodeData,
    expiresAt: session.expiresAt.toISOString(),
    error: session.error,
    message: session.message,
  };

  res.json(response);
});

// Error handler
app.use((err: Error, _req: Request, res: Response, _next: NextFunction) => {
  console.error('[pairing-service] Error:', err);
  res.status(500).json({ error: 'Internal server error' });
});

// Start server
app.listen(PORT, '127.0.0.1', () => {
  console.log(`[pairing-service] Running on http://127.0.0.1:${PORT}`);
  console.log('[pairing-service] Endpoints:');
  console.log(`  POST /api/pairing/:channelId - Start pairing`);
  console.log(`  GET  /api/pairing/:sessionId - Get pairing status`);
});

