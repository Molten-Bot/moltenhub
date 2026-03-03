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
export declare function startSignalPairing(session: PairingSession): Promise<void>;
export declare function isSignalConnected(): boolean;
//# sourceMappingURL=signal.d.ts.map