// Terminal Manager class with reconnection logic
class TerminalManager {
    constructor() {
        this.terminal = null;
        this.socket = null;
        this.isConnected = false;
        this.reconnectAttempts = 0;
        this.reconnectDelay = 5000; // Start with 5 seconds

        this.initializeTerminal();
        this.connect();
        this.setupEventListeners();
    }

    initializeTerminal() {
        // Initialize the terminal
        this.terminal = new Terminal({
            cursorBlink: true,
            theme: {
                background: '#1e1e1e',
                foreground: '#ffffff'
            },
            fontFamily: 'Courier New, monospace',
            fontSize: 14
        });

        // Attach terminal to the DOM
        this.terminal.open(document.getElementById('terminal'));
        
        // Wait for terminal to be fully rendered, then fit it
        setTimeout(() => {
            this.fitTerminal();
            // Fit again after a longer delay to ensure everything is loaded
            setTimeout(() => {
                this.fitTerminal();
            }, 500);
        }, 100);
        
        this.terminal.focus();
    }
    
    fitTerminal() {
        // Use a small delay to ensure DOM is ready
        setTimeout(() => {
            if (this.terminal && this.terminal.element) {
                try {
                    // Get terminal container dimensions
                    const container = document.getElementById('terminal');
                    const rect = container.getBoundingClientRect();
                    
                    console.log(`Container dimensions: ${rect.width}x${rect.height}`);
                    
                    // Create a test element with the same font settings as the terminal
                    const testElement = document.createElement('div');
                    testElement.style.fontFamily = 'Courier New, monospace';
                    testElement.style.fontSize = '14px';
                    testElement.style.lineHeight = 'normal';
                    testElement.style.position = 'absolute';
                    testElement.style.visibility = 'hidden';
                    testElement.style.whiteSpace = 'pre';
                    testElement.textContent = 'M\nM\nM'; // 3 lines to measure line height
                    document.body.appendChild(testElement);
                    
                    const charWidth = testElement.offsetWidth;
                    const totalHeight = testElement.offsetHeight;
                    const lineHeight = totalHeight / 3; // Height of one line
                    
                    document.body.removeChild(testElement);
                    
                    // Calculate available space (subtract small padding)
                    const availableWidth = rect.width - 4; // Small padding
                    const availableHeight = rect.height - 4; // Small padding
                    
                    // Calculate optimal dimensions
                    const cols = Math.max(1, Math.floor(availableWidth / charWidth));
                    const rows = Math.max(1, Math.floor(availableHeight / lineHeight));
                    
                    console.log(`Sizing: char=${charWidth}px, line=${lineHeight}px, grid=${cols}x${rows}`);
                    
                    // Resize terminal
                    this.terminal.resize(cols, rows);
                    
                } catch (error) {
                    console.warn('Could not resize terminal:', error);
                }
            }
        }, 100);
    }

    connect() {
        try {
            // Silent connection - no status messages in terminal

            // Open WebSocket connection
            this.socket = new WebSocket('ws://localhost:4000/ws');

            this.socket.onopen = () => {
                this.isConnected = true;
                this.reconnectAttempts = 0;
                this.reconnectDelay = 5000; // Reset to 5 seconds

                this.terminal.focus();

                // Set up client-side keepalive
                setInterval(() => {
                    if (this.socket.readyState === WebSocket.OPEN) {
                        this.socket.send('\x00');
                    }
                }, 5 * 60 * 1000); // Every 5 minutes
            };

            this.socket.onmessage = (event) => {
                // Handle ping frames
                if (event.data === '') {
                    return;
                }
                this.terminal.write(event.data);
            };

            this.socket.onclose = () => {
                this.isConnected = false;

                // Silent disconnection - no messages shown

                // Always attempt to reconnect - never give up
                this.reconnectAttempts++;                // Progressive delay: 5s for first few attempts, then 30s
                let delay = this.reconnectAttempts <= 3 ? 5000 : 30000;

                setTimeout(() => {
                    if (!this.isConnected) {
                        this.connect();
                    }
                }, delay);
            };

            this.socket.onerror = (error) => {
                console.error('Terminal WebSocket error:', error);
                // Silent error handling - no terminal messages
            };

        } catch (error) {
            console.error('Failed to connect to terminal WebSocket:', error);
            // Silent error handling - no terminal messages
        }
    }

    setupEventListeners() {
        // Handle browser window resize
        window.addEventListener('resize', () => {
            this.fitTerminal();
        });
        
        // Handle panel resize (for VS Code-style panels)
        if (window.panelManager) {
            const originalUpdateLayout = window.panelManager.updateLayout;
            window.panelManager.updateLayout = (...args) => {
                originalUpdateLayout.apply(window.panelManager, args);
                setTimeout(() => this.fitTerminal(), 100);
            };
        }
        
        // Send terminal input to WebSocket
        this.terminal.onData(data => {
            console.log('Sending data:', JSON.stringify(data));
            if (this.socket && this.socket.readyState === WebSocket.OPEN) {
                this.socket.send(data);
            }
            // Silent when not connected - just ignore input
        });

        // Ensure terminal stays focused when clicked
        document.getElementById('terminal').addEventListener('click', () => {
            this.terminal.focus();
        });

        // Handle terminal resize
        window.addEventListener('resize', () => {
            setTimeout(() => this.fitTerminal(), 100);
        });

        // Resize when the container might change
        document.addEventListener('DOMContentLoaded', () => {
            setTimeout(() => this.fitTerminal(), 200);
        });

        // Initial resize
        setTimeout(() => this.fitTerminal(), 100);
    }

    // Keep the old resizeTerminal method but call fitTerminal for consistency
    resizeTerminal() {
        this.fitTerminal();
    }
}

// Initialize terminal manager when page loads
const terminalManager = new TerminalManager();