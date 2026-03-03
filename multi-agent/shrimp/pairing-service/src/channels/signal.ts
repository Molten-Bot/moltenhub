import { updateSession } from '../session-manager.js';
import type { PairingSession } from '../types.js';

/**
 * Signal pairing is more complex than WhatsApp and requires signal-cli.
 * This is a stub implementation that can be expanded later.
 * 
 * Signal uses a different pairing mechanism:
 * 1. Generate a device linking code
 * 2. Display QR code containing the linking URI
 * 3. User scans with Signal app
 * 4. Signal app confirms the link
 * 
 * For now, we return a placeholder indicating Signal is not yet implemented.
 */

export async function startSignalPairing(session: PairingSession): Promise<void> {
  console.log('[signal] Signal pairing requested for session:', session.sessionId);
  
  // Signal pairing requires signal-cli which is not yet integrated
  updateSession(session.sessionId, {
    status: 'error',
    error: 'Signal pairing is not yet implemented. Please use WhatsApp or credential-based channels.',
    message: 'Signal integration coming soon',
  });
}

export function isSignalConnected(): boolean {
  // Placeholder - would check signal-cli status
  return false;
}

