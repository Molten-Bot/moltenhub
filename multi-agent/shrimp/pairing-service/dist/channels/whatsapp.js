import QRCode from 'qrcode';
import { updateSession } from '../session-manager.js';
import { makeWASocket, useMultiFileAuthState, fetchLatestBaileysVersion, } from '@whiskeysockets/baileys';
import pino from 'pino';
import * as fs from 'fs';
import * as path from 'path';
// Active WhatsApp socket instance (one per pod)
let whatsappSocket = null;
let isClientInitializing = false;
let saveCreds = null;
let socketConnectionState = null;
// Track the current session ID for event handlers
let currentSessionId = null;
// Track if credentials were saved during pairing (indicates successful QR scan)
// The 515 error after credential save is EXPECTED - we need to reconnect
let credentialsSavedDuringPairing = false;
// Track if we're in a reconnection attempt after 515
let isReconnecting = false;
// Get the credentials path that OpenClaw expects
// OpenClaw uses: ~/.openclaw/credentials/whatsapp/<accountId>/creds.json
function getCredentialsPath(accountId = 'default') {
    const homeDir = process.env.HOME || '/home/moltenbot';
    return path.join(homeDir, '.openclaw', 'credentials', 'whatsapp', accountId);
}
export async function startWhatsAppPairing(session) {
    // Update the current session ID - all events will now go to this session
    currentSessionId = session.sessionId;
    // If there's already a client initializing/running, check its state
    if (isClientInitializing) {
        console.log('[whatsapp] Client is initializing, waiting...');
        updateSession(session.sessionId, {
            status: 'pending',
            message: 'WhatsApp client is initializing, please wait...',
        });
        return;
    }
    if (whatsappSocket) {
        console.log('[whatsapp] Socket already exists, state:', socketConnectionState, 'for session:', session.sessionId);
        // If already connected, report success
        if (whatsappSocket.user) {
            updateSession(session.sessionId, {
                status: 'success',
                message: 'WhatsApp is already connected!',
            });
            return;
        }
        // If socket is connecting, wait
        if (socketConnectionState === 'connecting') {
            updateSession(session.sessionId, {
                status: 'pending',
                message: 'WhatsApp client is connecting, waiting for QR code...',
            });
            return;
        }
        // If socket is closed or in unknown state, clean up and start fresh
        if (socketConnectionState === 'close' || socketConnectionState === null) {
            console.log('[whatsapp] Socket is closed/stale, cleaning up for fresh start');
            cleanupClient();
            // Fall through to create new socket
        }
        else {
            // Socket exists but not authenticated - waiting for QR
            updateSession(session.sessionId, {
                status: 'pending',
                message: 'WhatsApp client already running, waiting for QR code...',
            });
            return;
        }
    }
    isClientInitializing = true;
    try {
        updateSession(session.sessionId, {
            status: 'pending',
            message: 'Starting WhatsApp (Baileys)...',
        });
        // Use the path OpenClaw expects for credentials
        const authDir = getCredentialsPath('default');
        console.log('[whatsapp] Using auth directory:', authDir);
        // Clear any stale credentials from failed pairing attempts
        // This ensures we get a fresh QR code
        if (fs.existsSync(authDir)) {
            console.log('[whatsapp] Clearing stale credentials for fresh pairing...');
            fs.rmSync(authDir, { recursive: true, force: true });
        }
        // Ensure the directory exists
        fs.mkdirSync(authDir, { recursive: true });
        // Initialize Baileys auth state
        const { state, saveCreds: saveCredsFunc } = await useMultiFileAuthState(authDir);
        saveCreds = saveCredsFunc;
        // Create a silent logger for Baileys
        const logger = pino({ level: 'silent' });
        // Fetch the latest WhatsApp Web version to avoid 405 errors
        // This is critical - WhatsApp frequently updates their protocol
        console.log('[whatsapp] Fetching latest WhatsApp Web version...');
        const { version, isLatest } = await fetchLatestBaileysVersion();
        console.log('[whatsapp] Using WhatsApp Web version:', version, 'isLatest:', isLatest);
        // Create the WhatsApp socket with the latest version
        whatsappSocket = makeWASocket({
            auth: state,
            version, // Use the fetched latest version
            logger,
            printQRInTerminal: false, // We handle QR ourselves
            browser: ['OpenClaw', 'Chrome', '120.0.0'],
        });
        // Handle connection updates
        whatsappSocket.ev.on('connection.update', async (update) => {
            const { connection, lastDisconnect, qr } = update;
            console.log('[whatsapp] Connection update:', { connection, hasQR: !!qr });
            // Track connection state for socket reuse decisions
            if (connection) {
                socketConnectionState = connection;
            }
            if (qr && currentSessionId) {
                // Generate QR code image
                try {
                    const qrDataUrl = await QRCode.toDataURL(qr, {
                        width: 256,
                        margin: 2,
                        errorCorrectionLevel: 'M',
                    });
                    updateSession(currentSessionId, {
                        status: 'qr_ready',
                        qrCodeData: qrDataUrl,
                        qrCodeRaw: qr,
                        message: 'Scan the QR code with WhatsApp on your phone',
                    });
                }
                catch (err) {
                    console.error('[whatsapp] Failed to generate QR image:', err);
                }
            }
            if (connection === 'close') {
                const statusCode = lastDisconnect?.error?.output?.statusCode;
                console.log('[whatsapp] Connection closed, statusCode:', statusCode, 'credentialsSaved:', credentialsSavedDuringPairing);
                // 515 = "Stream Errored (restart required)" - this is EXPECTED after successful QR pairing
                // If credentials were saved (indicating QR was scanned successfully), we need to reconnect
                if (statusCode === 515 && credentialsSavedDuringPairing && !isReconnecting) {
                    console.log('[whatsapp] Pairing completed! Reconnecting with saved credentials...');
                    if (currentSessionId) {
                        updateSession(currentSessionId, {
                            status: 'pending',
                            message: 'QR scanned successfully! Completing connection...',
                        });
                    }
                    // Close the old socket without clearing credentials
                    if (whatsappSocket) {
                        try {
                            whatsappSocket.end(undefined);
                        }
                        catch (e) {
                            // Ignore cleanup errors
                        }
                        whatsappSocket = null;
                    }
                    // Reconnect with saved credentials
                    isReconnecting = true;
                    setTimeout(() => reconnectWithSavedCredentials(authDir), 1000);
                    return;
                }
                // For other close reasons, or if reconnection already attempted, clean up
                if (currentSessionId && !isReconnecting) {
                    updateSession(currentSessionId, {
                        status: 'error',
                        error: `Connection closed (code: ${statusCode}). Please try pairing again.`,
                    });
                }
                // Don't clean up if we're about to reconnect
                if (!isReconnecting) {
                    cleanupClient();
                }
            }
            if (connection === 'open') {
                console.log('[whatsapp] Connected successfully!', isReconnecting ? '(after reconnect)' : '');
                // Reset reconnection state
                isReconnecting = false;
                credentialsSavedDuringPairing = false;
                if (currentSessionId) {
                    updateSession(currentSessionId, {
                        status: 'success',
                        message: 'WhatsApp connected successfully!',
                        qrCodeData: undefined,
                    });
                }
            }
        });
        // Handle credential updates - CRITICAL for persistence
        // This fires when QR code is scanned successfully
        whatsappSocket.ev.on('creds.update', async () => {
            console.log('[whatsapp] Credentials updated, saving...');
            credentialsSavedDuringPairing = true; // Mark that pairing was successful
            if (saveCreds) {
                await saveCreds();
                console.log('[whatsapp] Credentials saved to:', authDir);
            }
        });
    }
    catch (error) {
        console.error('[whatsapp] Failed to start pairing:', error);
        if (currentSessionId) {
            updateSession(currentSessionId, {
                status: 'error',
                error: `Failed to start WhatsApp: ${error.message}`,
            });
        }
        cleanupClient();
    }
    finally {
        isClientInitializing = false;
    }
}
// Reconnect with saved credentials after 515 error (expected after successful pairing)
async function reconnectWithSavedCredentials(authDir) {
    console.log('[whatsapp] Reconnecting with saved credentials from:', authDir);
    try {
        // Load the saved credentials
        const { state, saveCreds: saveCredsFunc } = await useMultiFileAuthState(authDir);
        saveCreds = saveCredsFunc;
        const logger = pino({ level: 'silent' });
        // Fetch latest version again for the reconnection
        const { version, isLatest } = await fetchLatestBaileysVersion();
        console.log('[whatsapp] Reconnecting with WhatsApp Web version:', version, 'isLatest:', isLatest);
        // Create a new socket with the saved credentials
        whatsappSocket = makeWASocket({
            auth: state,
            version,
            logger,
            printQRInTerminal: false,
            browser: ['OpenClaw', 'Chrome', '120.0.0'],
        });
        socketConnectionState = 'connecting';
        // Handle connection updates for the reconnected socket
        whatsappSocket.ev.on('connection.update', async (update) => {
            const { connection, lastDisconnect } = update;
            console.log('[whatsapp] Reconnect connection update:', { connection });
            if (connection) {
                socketConnectionState = connection;
            }
            if (connection === 'open') {
                console.log('[whatsapp] Reconnection successful! WhatsApp is now connected.');
                isReconnecting = false;
                credentialsSavedDuringPairing = false;
                if (currentSessionId) {
                    updateSession(currentSessionId, {
                        status: 'success',
                        message: 'WhatsApp connected successfully!',
                        qrCodeData: undefined,
                    });
                }
            }
            if (connection === 'close') {
                const statusCode = lastDisconnect?.error?.output?.statusCode;
                console.log('[whatsapp] Reconnection failed, statusCode:', statusCode);
                isReconnecting = false;
                if (currentSessionId) {
                    updateSession(currentSessionId, {
                        status: 'error',
                        error: `Reconnection failed (code: ${statusCode}). Please try pairing again.`,
                    });
                }
                cleanupClient();
            }
        });
        // Handle credential updates
        whatsappSocket.ev.on('creds.update', async () => {
            if (saveCreds) {
                await saveCreds();
                console.log('[whatsapp] Credentials updated during reconnect');
            }
        });
    }
    catch (error) {
        console.error('[whatsapp] Failed to reconnect:', error);
        isReconnecting = false;
        if (currentSessionId) {
            updateSession(currentSessionId, {
                status: 'error',
                error: `Failed to reconnect: ${error.message}`,
            });
        }
        cleanupClient();
    }
}
function cleanupClient() {
    console.log('[whatsapp] Cleaning up client...');
    if (whatsappSocket) {
        try {
            whatsappSocket.end(undefined);
        }
        catch (e) {
            // Ignore cleanup errors
        }
        whatsappSocket = null;
        saveCreds = null;
    }
    socketConnectionState = null;
    credentialsSavedDuringPairing = false;
    isReconnecting = false;
}
export function isWhatsAppConnected() {
    return whatsappSocket?.user !== undefined;
}
//# sourceMappingURL=whatsapp.js.map