// Chat functionality
class ChatManager {
  constructor() {
    this.socket = null;
    this.isConnected = false;
    this.messageHistory = [];
    this.isTyping = false;
    this.reconnectAttempts = 0;
    this.reconnectDelay = 5000; // Start with 5 seconds
    this.currentStatusMessage = null;
    this.streamingMessage = null; // Track current streaming message
    this.streamingContent = ""; // Accumulate streaming content
    this.typingTimeout = null; // Track typing indicator timeout
    this.pendingStreamModel = null; // Model name for pending stream
    this.toolTimeout = null; // Track tool execution timeout

    this.initializeLibraries();
    this.initializeElements();
    this.setupEventListeners();
    this.connect();
  }

  initializeLibraries() {
    // Initialize highlight.js when available
    if (typeof hljs !== 'undefined') {
      hljs.configure({
        ignoreUnescapedHTML: true
      });
      console.log('Highlight.js initialized');
    } else {
      console.warn('Highlight.js not available');
    }

    // Check marked.js availability
    if (typeof marked !== 'undefined') {
      console.log('Marked.js available');
    } else {
      console.warn('Marked.js not available');
    }
  }

  initializeElements() {
    this.chatMessages = document.getElementById('chat-messages');
    this.chatInput = document.getElementById('chat-input');
    this.chatSend = document.getElementById('chat-send');
    this.aiStatus = document.getElementById('ai-status');
    this.stopButton = document.getElementById('stop-ai');

    if (!this.chatMessages || !this.chatInput || !this.chatSend || !this.aiStatus || !this.stopButton) {
      console.error('Chat elements not found in DOM');
      return;
    }
  }

  setupEventListeners() {
    // Send button click
    this.chatSend.addEventListener('click', () => this.sendMessage());

    // Stop button click
    this.stopButton.addEventListener('click', () => this.stopAI());

    // Enter key to send message
    this.chatInput.addEventListener('keypress', (e) => {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        this.sendMessage();
      }
    });

    // Auto-resize input and focus management
    this.chatInput.addEventListener('input', () => {
      this.adjustInputHeight();
    });

    // Mobile chat toggle
    const mobileToggle = document.getElementById('mobile-chat-toggle');
    if (mobileToggle) {
      mobileToggle.addEventListener('click', () => this.toggleMobileChat());
    }
  }

  // Mobile chat toggle functionality
  toggleMobileChat() {
    const chatPanel = document.querySelector('.lg\\:flex.lg\\:flex-none.lg\\:w-2\\/5');
    const terminalPanel = document.querySelector('.flex-none.w-full.lg\\:w-3\\/5');

    if (chatPanel && terminalPanel) {
      const isChatVisible = !chatPanel.classList.contains('hidden');

      if (isChatVisible) {
        // Hide chat, show terminal
        chatPanel.classList.add('hidden');
        terminalPanel.classList.remove('hidden', 'lg:w-3/5');
        terminalPanel.classList.add('w-full');
      } else {
        // Show chat, hide terminal on mobile
        chatPanel.classList.remove('hidden');
        chatPanel.classList.add('fixed', 'inset-0', 'z-20', 'lg:relative', 'lg:inset-auto');
        terminalPanel.classList.add('hidden', 'lg:block');
      }
    }
  }

  connect() {
    try {
      // Only show connecting message on first attempt
      if (this.reconnectAttempts === 0) {
        this.updateStatusMessage('Connecting to chat system...', 'connecting');
      }

      // Connect to the actual chat WebSocket endpoint
      this.socket = new WebSocket('ws://localhost:4000/chat_ws');

      this.socket.onopen = () => {
        console.log('Chat WebSocket connected');
        this.isConnected = true;
        this.reconnectAttempts = 0;
        this.reconnectDelay = 5000; // Reset to 5 seconds
        this.chatInput.disabled = false;
        this.chatSend.disabled = false;

        // Remove status message after successful connection
        if (this.currentStatusMessage) {
          this.currentStatusMessage.remove();
          this.currentStatusMessage = null;
        }
      };

      this.socket.onmessage = (event) => {
        this.handleWebSocketMessage(event.data);
      };

      this.socket.onclose = () => {
        console.log('Chat WebSocket disconnected');
        this.isConnected = false;
        this.chatInput.disabled = true;
        this.chatSend.disabled = true;

        // Show disconnection status clearly to user
        this.updateStatusMessage('Chat disconnected - reconnecting...', 'disconnected');

        // Always attempt to reconnect - never give up
        this.reconnectAttempts++;

        // Progressive delay: 5s for first few attempts, then 30s
        let delay = this.reconnectAttempts <= 3 ? 5000 : 30000;

        setTimeout(() => {
          if (!this.isConnected) {
            this.connect();
          }
        }, delay);
      };

      this.socket.onerror = (error) => {
        console.error('Chat WebSocket error:', error);
        // Show error to user - don't hide it
        this.updateStatusMessage('Chat connection error - retrying...', 'disconnected');
      };

    } catch (error) {
      console.error('Failed to connect to chat WebSocket:', error);
      // Silent failure - will retry automatically
    }
  }

  addErrorMessage(content) {
    // Validate content before creating error message div
    if (!content || (typeof content === 'string' && content.trim() === '')) {
      console.warn('Attempted to create error message with empty content, skipping');
      return;
    }

    const messageDiv = document.createElement('div');
    messageDiv.className = 'chat-message mb-3 p-3 rounded-lg bg-red-900 border border-red-600 transition-smooth';

    const timestamp = new Date();
    const formattedTime = timestamp.toLocaleTimeString();

    const headerDiv = document.createElement('div');
    headerDiv.className = 'message-header flex justify-between items-center text-sm mb-1';
    headerDiv.innerHTML = `
      <span class="text-red-400">🚨 Error</span>
      <span class="ml-auto flex-none w-20">${formattedTime}</span>
    `;

    const contentDiv = document.createElement('div');
    contentDiv.className = 'message-content break-words';
    contentDiv.textContent = content;

    messageDiv.appendChild(headerDiv);
    messageDiv.appendChild(contentDiv);

    // Batch DOM update to prevent layout thrashing
    requestAnimationFrame(() => {
      this.chatMessages.appendChild(messageDiv);
      this.scrollToBottom();
    });
  }

  ensureThinkingIndicatorAtBottom() {
    // If there's a thinking indicator and we're currently thinking, move it to the bottom
    if (this.isTyping) {
      const typingIndicator = document.getElementById('typing-indicator');
      if (typingIndicator) {
        // Remove it and re-add at the end
        typingIndicator.remove();
        this.chatMessages.appendChild(typingIndicator);
      }
    }
  }

  addMessage(content, type = 'user', model = null) {
    // Validate content before creating message div
    if (!content || (typeof content === 'string' && content.trim() === '')) {
      console.warn('Attempted to create message with empty content, skipping');
      return;
    }

    const messageDiv = document.createElement('div');

    // Apply Tailwind classes based on message type with layout stability
    if (type === 'user') {
      messageDiv.className = 'chat-message mb-3 p-3 rounded-lg bg-sky-900 mr-4 transition-smooth';
    } else if (type === 'ai') {
      messageDiv.className = 'chat-message mb-3 p-3 rounded-lg bg-slate-700 ml-4 transition-smooth';
    } else {
      messageDiv.className = 'chat-message mb-3 p-3 rounded-lg bg-slate-600 transition-smooth';
    }

    const timestamp = new Date();
    const formattedTime = timestamp.toLocaleTimeString();

    const headerDiv = document.createElement('div');
    headerDiv.className = 'message-header flex justify-between items-center text-sm mb-1';

    const senderLabel = type === 'user' ? '★ You' :
      type === 'ai' ? `⚛ ${model || 'AI'}` : '🖧 System';

    headerDiv.innerHTML = `
      <span class="text-blue-300 flex-none">${senderLabel}</span>
      <span class="ml-auto flex-none w-20">${formattedTime}</span>
    `;

    const contentDiv = document.createElement('div');
    contentDiv.className = 'message-content text-slate-200 break-words markdown-body markdown-content';

    // Check if this is an AI message with channel structure
    if (type === 'ai' && content.includes('<|channel|>')) {
      console.log('Detected channel message:', content.substring(0, 200) + '...');
      contentDiv.innerHTML = this.formatChannelMessage(content);
    } else {
      // Format the content with markdown
      const formattedContent = this.formatMessage(content);
      contentDiv.innerHTML = formattedContent;
    }

    messageDiv.appendChild(headerDiv);
    messageDiv.appendChild(contentDiv);

    // Batch DOM update to prevent layout thrashing
    requestAnimationFrame(() => {
      this.chatMessages.appendChild(messageDiv);
      this.ensureThinkingIndicatorAtBottom();
      this.scrollToBottom();
    });
  }

  // Start a new streaming message
  startStreamingMessage(model = null) {
    const messageDiv = document.createElement('div');
    messageDiv.className = 'chat-message mb-3 p-3 rounded-lg bg-slate-700 ml-4 transition-smooth streaming-message';

    const timestamp = new Date();
    const formattedTime = timestamp.toLocaleTimeString();

    const headerDiv = document.createElement('div');
    headerDiv.className = 'message-header flex justify-between items-center text-sm mb-1';

    const senderLabel = `⚛ ${model || 'AI'}`;

    headerDiv.innerHTML = `
      <span class="text-blue-300 flex-none">${senderLabel}</span>
      <span class="ml-auto flex-none w-20">${formattedTime}</span>
    `;

    const contentDiv = document.createElement('div');
    contentDiv.className = 'message-content text-slate-200 break-words markdown-body markdown-content streaming-content';

    // Add streaming cursor
    const cursorSpan = document.createElement('span');
    cursorSpan.className = 'streaming-cursor';
    cursorSpan.innerHTML = '▌';
    contentDiv.appendChild(cursorSpan);

    messageDiv.appendChild(headerDiv);
    messageDiv.appendChild(contentDiv);

    // Add to DOM
    this.chatMessages.appendChild(messageDiv);
    this.scrollToBottom();

    // Store references
    this.streamingMessage = messageDiv;
    this.streamingContent = "";

    return { messageDiv, contentDiv };
  }

  // Add content to the streaming message
  appendToStreamingMessage(chunk) {
    if (!this.streamingMessage) {
      console.warn('No streaming message active');
      return;
    }

    this.streamingContent += chunk;

    const contentDiv = this.streamingMessage.querySelector('.streaming-content');
    if (contentDiv) {
      // Format the accumulated content with markdown but keep the cursor
      const formattedContent = this.formatMessage(this.streamingContent);
      contentDiv.innerHTML = formattedContent + '<span class="streaming-cursor">▌</span>';

      // Scroll to bottom to follow the stream
      this.scrollToBottom();
    }
  }

  // Add content to the thinking section
  appendToThinkingMessage(chunk) {
    if (!this.streamingMessage) {
      console.warn('No streaming message active');
      return;
    }

    this.thinkingContent += chunk;

    // Find or create thinking section
    let thinkingSection = this.streamingMessage.querySelector('.thinking-section');
    if (!thinkingSection) {
      // Create thinking section before the main content
      const contentDiv = this.streamingMessage.querySelector('.streaming-content');
      thinkingSection = document.createElement('details');
      thinkingSection.className = 'thinking-section mb-2';
      thinkingSection.innerHTML = `
        <summary class="thinking-summary text-xs text-slate-400 hover:text-slate-300 cursor-pointer select-none p-2 rounded bg-slate-800 border border-slate-600">
          <span class="inline-flex items-center">
            <svg class="w-3 h-3 mr-1 transform transition-transform" viewBox="0 0 20 20" fill="currentColor">
              <path fill-rule="evenodd" d="M7.293 14.707a1 1 0 010-1.414L10.586 10 7.293 6.707a1 1 0 011.414-1.414l4 4a1 1 0 010 1.414l-4 4a1 1 0 01-1.414 0z" clip-rule="evenodd" />
            </svg>
            💭 AI Thinking Process
          </span>
        </summary>
        <div class="thinking-content text-xs text-slate-500 mt-2 p-2 bg-slate-900 rounded border-l-2 border-slate-600">
          <span class="streaming-cursor">▌</span>
        </div>
      `;
      contentDiv.parentElement.insertBefore(thinkingSection, contentDiv);
    }

    // Update thinking content
    const thinkingContentDiv = thinkingSection.querySelector('.thinking-content');
    if (thinkingContentDiv) {
      thinkingContentDiv.innerHTML = this.formatMessage(this.thinkingContent) + '<span class="streaming-cursor">▌</span>';
    }
  }

  // Finish the streaming message
  finishStreamingMessage() {
    // If no streaming message was ever created (no content received), just clean up
    if (!this.streamingMessage) {
      console.log('No streaming message to finish - no content was received');
      this.streamingContent = "";
      this.thinkingContent = "";
      this.pendingStreamModel = null;
      return;
    }

    // Check if we have any content to display
    if (!this.streamingContent || this.streamingContent.trim() === '') {
      console.warn('Finishing streaming message with no content, removing message div');
      // Remove the empty streaming message div
      this.streamingMessage.remove();
      this.streamingMessage = null;
      this.streamingContent = "";
      this.thinkingContent = "";
      this.pendingStreamModel = null;
      return;
    }

    const contentDiv = this.streamingMessage.querySelector('.streaming-content');
    if (contentDiv) {
      // Remove cursor and finalize content
      const formattedContent = this.formatMessage(this.streamingContent);
      contentDiv.innerHTML = formattedContent;
    }

    // Finalize thinking section if present
    const thinkingContentDiv = this.streamingMessage.querySelector('.thinking-content');
    if (thinkingContentDiv && this.thinkingContent) {
      const formattedThinking = this.formatMessage(this.thinkingContent);
      thinkingContentDiv.innerHTML = formattedThinking;
    }

    // Remove streaming class
    this.streamingMessage.classList.remove('streaming-message');

    // Clean up references
    this.streamingMessage = null;
    this.streamingContent = "";
    this.thinkingContent = "";
    this.pendingStreamModel = null;
  }

  addSystemMessage(content, status = 'connected') {
    // Validate content before creating message div
    if (!content || (typeof content === 'string' && content.trim() === '')) {
      console.warn('Attempted to create system message with empty content, skipping');
      return;
    }

    const messageDiv = document.createElement('div');
    messageDiv.className = 'mb-3 p-2 rounded bg-slate-800 border-l-4 border-yellow-500 text-sm';

    const statusSpan = document.createElement('span');
    const statusClasses = {
      'connected': 'bg-green-600 text-white',
      'connecting': 'bg-yellow-600 text-white',
      'disconnected': 'bg-red-600 text-white',
      'error': 'bg-red-700 text-white',
      'stopped': 'bg-slate-600 text-white'
    };
    statusSpan.className = `inline-block px-2 py-1 rounded text-xs font-medium ml-2 ${statusClasses[status] || 'bg-slate-600 text-white'}`;
    statusSpan.textContent = status;

    const contentSpan = document.createElement('span');
    contentSpan.className = 'text-slate-300';
    contentSpan.textContent = content + ' ';

    messageDiv.appendChild(contentSpan);
    messageDiv.appendChild(statusSpan);

    this.chatMessages.appendChild(messageDiv);
    this.ensureThinkingIndicatorAtBottom();
    this.scrollToBottom();
  }

  updateStatusMessage(content, status = 'connecting') {
    // If we have an existing status message, update it
    if (this.currentStatusMessage) {
      const statusSpan = this.currentStatusMessage.querySelector('.connection-status');
      this.currentStatusMessage.innerHTML = `${content} `;

      const newStatusSpan = document.createElement('span');
      newStatusSpan.className = `connection-status ${status}`;
      newStatusSpan.textContent = status;
      this.currentStatusMessage.appendChild(newStatusSpan);
    } else {
      // Create a new status message
      const messageDiv = document.createElement('div');
      messageDiv.className = 'chat-message system status-message';

      const statusSpan = document.createElement('span');
      statusSpan.className = `connection-status ${status}`;
      statusSpan.textContent = status;

      messageDiv.innerHTML = `${content} `;
      messageDiv.appendChild(statusSpan);

      this.chatMessages.appendChild(messageDiv);
      this.currentStatusMessage = messageDiv;
    }
    this.scrollToBottom();
  }

  showTypingIndicator() {
    if (this.isTyping) return;

    this.isTyping = true;

    // Clear any existing typing timeout
    if (this.typingTimeout) {
      clearTimeout(this.typingTimeout);
    }

    // Remove any existing typing indicator
    const existingIndicator = document.getElementById('typing-indicator');
    if (existingIndicator) {
      existingIndicator.remove();
    }

    const typingDiv = document.createElement('div');
    typingDiv.className = 'typing-indicator mb-2';
    typingDiv.id = 'typing-indicator';

    const timestamp = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });

    typingDiv.innerHTML = `
        <div class="typing-summary">
            <span class="typing-icon">⚛</span>
            <span class="typing-text">AI is thinking...</span>
            <span class="typing-time">${timestamp}</span>
            <div class="typing-dots">
                <div class="typing-dot"></div>
                <div class="typing-dot"></div>
                <div class="typing-dot"></div>
            </div>
        </div>
        `;

    // Always append at the end (bottom of chat)
    this.chatMessages.appendChild(typingDiv);
    this.scrollToBottom();

    // Set timeout to automatically hide typing indicator after 30 seconds
    this.typingTimeout = setTimeout(() => {
      this.hideTypingIndicator();
    }, 30000);
  }

  hideTypingIndicator() {
    // Clear the typing timeout
    if (this.typingTimeout) {
      clearTimeout(this.typingTimeout);
      this.typingTimeout = null;
    }

    const typingIndicator = document.getElementById('typing-indicator');
    if (typingIndicator) {
      // Fade out instead of immediate removal to reduce layout shift
      typingIndicator.style.opacity = '0';
      typingIndicator.style.transform = 'scale(0.95)';
      typingIndicator.style.transition = 'opacity 0.2s, transform 0.2s';

      setTimeout(() => {
        if (typingIndicator && typingIndicator.parentNode) {
          typingIndicator.remove();
        }
      }, 200);
    }
    this.isTyping = false;
  }

  formatChannelMessage(content) {
    try {
      // Parse channel-based message structure
      const channels = this.parseChannels(content);
      let html = '';

      channels.forEach(channel => {
        if (channel.type === 'analysis') {
          // Render thinking section as collapsible with low contrast
          html += `
            <details class="thinking-section mb-2">
              <summary class="thinking-summary text-xs text-slate-400 hover:text-slate-300 cursor-pointer select-none p-2 rounded bg-slate-800 border border-slate-600">
                <span class="inline-flex items-center">
                  <svg class="w-3 h-3 mr-1 transform transition-transform" viewBox="0 0 20 20" fill="currentColor">
                    <path fill-rule="evenodd" d="M7.293 14.707a1 1 0 010-1.414L10.586 10 7.293 6.707a1 1 0 011.414-1.414l4 4a1 1 0 010 1.414l-4 4a1 1 0 01-1.414 0z" clip-rule="evenodd" />
                  </svg>
                  💭 AI Thinking Process
                </span>
              </summary>
              <div class="thinking-content text-xs text-slate-500 mt-2 p-2 bg-slate-900 rounded border-l-2 border-slate-600">
                ${this.formatMessage(channel.content)}
              </div>
            </details>
          `;
        } else if (channel.type === 'final') {
          // Render main response normally
          html += `<div class="final-response">${this.formatMessage(channel.content)}</div>`;
        }
      });

      return html;
    } catch (error) {
      console.warn('Failed to parse channel message, using basic formatting:', error);
      return this.formatMessage(content);
    }
  }

  parseChannels(content) {
    const channels = [];

    // Match channel patterns: <|channel|>type<|message|>content<|end|> or <|start|>assistant<|channel|>type<|message|>content
    const channelRegex = /<\|channel\|>([^<]+)<\|message\|>(.*?)(?=<\|end\|>|<\|start\|>|$)/gs;

    let match;
    while ((match = channelRegex.exec(content)) !== null) {
      channels.push({
        type: match[1].trim(),
        content: match[2].trim()
      });
    }

    // If no channels found, try the alternative format with <|start|>assistant<|channel|>
    if (channels.length === 0) {
      const altRegex = /<\|start\|>assistant<\|channel\|>([^<]+)<\|message\|>(.*?)(?=<\|end\|>|<\|start\|>|$)/gs;
      while ((match = altRegex.exec(content)) !== null) {
        channels.push({
          type: match[1].trim(),
          content: match[2].trim()
        });
      }
    }

    // If still no channels, treat as single final message
    if (channels.length === 0) {
      channels.push({
        type: 'final',
        content: content
      });
    }

    return channels;
  }

  formatMessage(content) {
    // Debug: Log what we're trying to format
    console.log('=== Format Message Debug ===');
    console.log('Raw content length:', content.length);
    console.log('Content preview (first 300 chars):', JSON.stringify(content.substring(0, 300)));
    console.log('Content has links?', content.includes('[') && content.includes(']('));
    console.log('Content has tables?', content.includes('|'));
    console.log('marked available?', typeof marked !== 'undefined');
    console.log('marked.parse available?', typeof marked !== 'undefined' && typeof marked.parse === 'function');
    console.log('============================');

    // Use marked.js for proper markdown parsing if available
    if (typeof marked !== 'undefined' && (typeof marked === 'function' || typeof marked.parse === 'function')) {
      try {
        // Configure custom renderer for links and other elements
        const renderer = new marked.Renderer();

        // Override link rendering to open in new tab
        renderer.link = function (href, title, text) {
          const cleanHref = href.replace(/[<>]/g, ''); // Basic sanitization
          const titleAttr = title ? ` title="${title}"` : '';
          return `<a href="${cleanHref}" target="_blank" rel="noopener noreferrer"${titleAttr}>${text}</a>`;
        };

        // Override heading rendering to ensure proper styling
        renderer.heading = function (text, level) {
          const escapedText = text.toLowerCase().replace(/[^\w]+/g, '-');
          return `<h${level} id="${escapedText}">${text}</h${level}>`;
        };

        // Configure marked options (compatible with both old and new versions)
        const markedOptions = {
          renderer: renderer,
          highlight: function (code, lang) {
            // Use highlight.js for syntax highlighting if available
            if (typeof hljs !== 'undefined') {
              try {
                if (lang && hljs.getLanguage(lang)) {
                  return hljs.highlight(lang, code).value;
                } else {
                  return hljs.highlightAuto(code).value;
                }
              } catch (e) {
                console.warn('Highlight.js error:', e);
                return code;
              }
            }
            return code;
          },
          breaks: true, // Convert line breaks to <br>
          gfm: true, // GitHub flavored markdown
          sanitize: false, // Allow HTML (be careful in production)
          pedantic: false,
          smartLists: true,
          smartypants: false
        };

        // Try to use marked.js - handle different versions gracefully
        let htmlContent;

        try {
          // Configure marked options for v5+
          const markedOptions = {
            breaks: true,
            gfm: true,
            sanitize: false,
            smartLists: true,
            mangle: false  // Disable deprecated mangle parameter to clear warning
          };

          // Try marked.parse() first (v5+)
          if (typeof marked.parse === 'function') {
            htmlContent = marked.parse(content, markedOptions);
          }
          // Fallback to marked() function (v4 and below)
          else if (typeof marked === 'function') {
            htmlContent = marked(content, markedOptions);
          }
          else {
            throw new Error('marked function not available');
          }
        } catch (parseError) {
          console.warn('Marked.js parsing failed:', parseError);
          throw parseError;
        }

        console.log('Marked output:', htmlContent.substring(0, 200) + '...');

        // Post-process the HTML to wrap tables for better responsiveness
        const tempDiv = document.createElement('div');
        tempDiv.innerHTML = htmlContent;

        // Wrap tables in scrollable containers
        const tables = tempDiv.querySelectorAll('table');
        tables.forEach(table => {
          const wrapper = document.createElement('div');
          wrapper.className = 'table-wrapper';
          table.parentNode.insertBefore(wrapper, table);
          wrapper.appendChild(table);
        });

        const processedContent = tempDiv.innerHTML;

        // Apply syntax highlighting to any remaining code blocks after DOM update
        setTimeout(() => {
          if (typeof hljs !== 'undefined') {
            const codeBlocks = document.querySelectorAll('pre code:not(.hljs)');
            console.log('Found code blocks to highlight:', codeBlocks.length);
            codeBlocks.forEach((block) => {
              hljs.highlightElement(block);
            });
          }
        }, 100);

        return processedContent;
      } catch (e) {
        console.warn('Markdown parsing failed, falling back to basic formatting:', e);
        return this.basicFormatMessage(content);
      }
    } else {
      console.warn('marked.js not available, using basic formatting');
    }

    // Fallback to basic formatting if marked.js not available
    return this.basicFormatMessage(content);
  }

  basicFormatMessage(content) {
    console.log('Using basic formatting for content');
    // Enhanced basic markdown-like formatting
    let formatted = content
      // Handle code blocks first (multi-line)
      .replace(/```(\w+)?\n([\s\S]*?)```/g, '<pre><code class="language-$1">$2</code></pre>')
      .replace(/```([\s\S]*?)```/g, '<pre><code>$1</code></pre>')
      // Handle inline code
      .replace(/`([^`]+)`/g, '<code>$1</code>')
      // Handle links - must come before other formatting
      .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>')
      // Handle automatic URL detection
      .replace(/(https?:\/\/[^\s]+)/g, '<a href="$1" target="_blank" rel="noopener noreferrer">$1</a>')
      // Handle headers (order matters - h3 before h2 before h1)
      .replace(/^### (.*$)/gm, '<h3>$1</h3>')
      .replace(/^## (.*$)/gm, '<h2>$1</h2>')
      .replace(/^# (.*$)/gm, '<h1>$1</h1>')
      // Handle bold and italic
      .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
      .replace(/\*([^*]+)\*/g, '<em>$1</em>')
      // Handle lists
      .replace(/^- (.*$)/gm, '<li>$1</li>')
      .replace(/(<li>.*<\/li>)/gs, '<ul>$1</ul>')
      .replace(/<\/ul>\s*<ul>/g, ''); // Merge consecutive lists

    // Basic table processing
    const lines = formatted.split('\n');
    let inTable = false;
    let tableRows = [];
    let result = [];

    for (let line of lines) {
      if (line.includes('|') && line.trim().length > 0) {
        if (!inTable) {
          inTable = true;
          tableRows = [];
        }
        tableRows.push(line);
      } else {
        if (inTable) {
          // Process the table
          if (tableRows.length > 0) {
            result.push(this.processBasicTable(tableRows));
          }
          inTable = false;
          tableRows = [];
        }
        result.push(line);
      }
    }

    // Handle table at end of content
    if (inTable && tableRows.length > 0) {
      result.push(this.processBasicTable(tableRows));
    }

    return result.join('\n').replace(/\n/g, '<br>');
  }

  processBasicTable(rows) {
    let html = '<div class="table-wrapper"><table>';
    let isFirstRow = true;

    for (let row of rows) {
      if (row.trim().match(/^[|\s-]+$/)) continue; // Skip separator rows

      const cells = row.split('|').map(cell => cell.trim()).filter(cell => cell.length > 0);
      if (cells.length === 0) continue;

      html += '<tr>';
      const tag = isFirstRow ? 'th' : 'td';
      for (let cell of cells) {
        html += `<${tag}>${cell}</${tag}>`;
      }
      html += '</tr>';
      isFirstRow = false;
    }

    html += '</table></div>';
    return html;
  }

  adjustInputHeight() {
    // Smooth auto-resize for textarea with layout shift prevention
    const maxHeight = 120;
    const minHeight = 40;

    // Reset height to measure content
    this.chatInput.style.height = minHeight + 'px';

    // Calculate required height
    const scrollHeight = this.chatInput.scrollHeight;
    const newHeight = Math.max(minHeight, Math.min(scrollHeight, maxHeight));

    // Apply new height smoothly
    if (this.chatInput.style.height !== newHeight + 'px') {
      this.chatInput.style.height = newHeight + 'px';
    }

    // Enable/disable scrolling based on content
    if (scrollHeight > maxHeight) {
      this.chatInput.style.overflowY = 'auto';
    } else {
      this.chatInput.style.overflowY = 'hidden';
    }
  }

  scrollToBottom() {
    // Use smooth scrolling to prevent jarring layout shifts
    requestAnimationFrame(() => {
      this.chatMessages.scrollTo({
        top: this.chatMessages.scrollHeight,
        behavior: 'smooth'
      });
    });
  }

  clearChat() {
    this.chatMessages.innerHTML = '';
    this.messageHistory = [];
  }

  exportChat() {
    const chatData = {
      timestamp: new Date().toISOString(),
      messages: this.messageHistory
    };

    const blob = new Blob([JSON.stringify(chatData, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);

    const a = document.createElement('a');
    a.href = url;
    a.download = `chat-export-${Date.now()}.json`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  }

  addToolUsageMessage(message) {
    // Validate message content and tool calls before creating div
    if (!message || (!message.content && !message.tool_calls)) {
      console.warn('Attempted to create tool usage message with no content or tool calls, skipping');
      return;
    }

    const messageDiv = document.createElement('div');
    messageDiv.className = 'chat-message tool-usage';
    messageDiv.dataset.toolCallId = message.tool_calls?.[0]?.id || 'unknown';

    const timestamp = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });

    // Create collapsed view
    const summaryDiv = document.createElement('div');
    summaryDiv.className = 'tool-summary';
    summaryDiv.innerHTML = `
      <span class="tool-icon">🔧</span>
      <span class="tool-text">${message.content}</span>
      <span class="tool-time">${timestamp}</span>
      <span class="expand-icon">▶</span>
    `;

    // Create expanded view (initially hidden)
    const detailsDiv = document.createElement('div');
    detailsDiv.className = 'tool-details hidden';

    const toolCallsHtml = message.tool_calls.map(toolCall => `
      <div class="tool-call">
        <strong>Tool:</strong> ${toolCall.function.name}<br>
        <strong>Arguments:</strong> <pre>${JSON.stringify(JSON.parse(toolCall.function.arguments), null, 2)}</pre>
      </div>
    `).join('');

    detailsDiv.innerHTML = `
      <div class="tool-calls">
        ${toolCallsHtml}
      </div>
      <div class="tool-results" data-tool-id="${message.tool_calls?.[0]?.id}">
        <em>Waiting for results...</em>
      </div>
    `;

    // Add click handler to toggle expanded view
    summaryDiv.addEventListener('click', () => {
      const isExpanded = !detailsDiv.classList.contains('hidden');
      detailsDiv.classList.toggle('hidden');
      summaryDiv.querySelector('.expand-icon').textContent = isExpanded ? '▶' : '▼';
    });

    messageDiv.appendChild(summaryDiv);
    messageDiv.appendChild(detailsDiv);

    this.chatMessages.appendChild(messageDiv);
    this.ensureThinkingIndicatorAtBottom();
    this.scrollToBottom();
  }

  updateToolResult(message) {
    // Find the tool usage message with matching tool call ID
    const toolUsageMessage = document.querySelector(`[data-tool-call-id="${message.tool_call?.id}"]`);
    if (toolUsageMessage) {
      const resultsDiv = toolUsageMessage.querySelector('.tool-results');
      if (resultsDiv) {
        try {
          const resultContent = JSON.parse(message.result.content);

          // Format the result for better readability
          let displayContent = '';
          let fullContent = '';
          let isTruncated = false;
          let resultSummary = '';

          if (resultContent.content) {
            // For web content, show a summary and truncated version
            resultSummary = this.generateWebContentSummary(resultContent);
            fullContent = resultContent.content;
            if (fullContent.length > 1000) {
              displayContent = fullContent.substring(0, 1000) + '\n... (content truncated, ' + (fullContent.length - 1000) + ' more characters)';
              isTruncated = true;
            } else {
              displayContent = fullContent;
            }
          } else if (resultContent.results) {
            // For search results, show a more readable format
            resultSummary = `Found ${resultContent.results_count || 'several'} search results`;
            fullContent = JSON.stringify(resultContent, null, 2);
            displayContent = this.formatSearchResults(resultContent);
          } else {
            // For other results, show the full JSON but formatted
            fullContent = JSON.stringify(resultContent, null, 2);
            if (fullContent.length > 2000) {
              displayContent = fullContent.substring(0, 2000) + '\n... (content truncated, ' + (fullContent.length - 2000) + ' more characters)';
              isTruncated = true;
            } else {
              displayContent = fullContent;
            }
          }

          let resultHtml = `
            <strong>Result:</strong>
            ${resultSummary ? `<div class="result-summary">${resultSummary}</div>` : ''}
            <pre class="tool-result-content">${displayContent}</pre>
          `;

          if (isTruncated) {
            resultHtml += `
              <button class="show-full-content" data-full-content="${encodeURIComponent(fullContent)}">
                Show Full Content
              </button>
            `;
          }

          resultsDiv.innerHTML = resultHtml;

          // Add click handler for show full content button
          if (isTruncated) {
            const showFullButton = resultsDiv.querySelector('.show-full-content');
            showFullButton.addEventListener('click', (e) => {
              const fullContent = decodeURIComponent(e.target.dataset.fullContent);
              const contentPre = resultsDiv.querySelector('.tool-result-content');
              contentPre.textContent = fullContent;
              e.target.style.display = 'none';
            });
          }

        } catch (e) {
          // If it's not JSON, show as-is but truncate if too long
          let content = message.result.content;
          let fullContent = content;
          let isTruncated = false;

          if (content.length > 1000) {
            content = content.substring(0, 1000) + '\n... (content truncated, ' + (fullContent.length - 1000) + ' more characters)';
            isTruncated = true;
          }

          let resultHtml = `
            <strong>Result:</strong>
            <pre class="tool-result-content">${content}</pre>
          `;

          if (isTruncated) {
            resultHtml += `
              <button class="show-full-content" data-full-content="${encodeURIComponent(fullContent)}">
                Show Full Content
              </button>
            `;
          }

          resultsDiv.innerHTML = resultHtml;

          // Add click handler for show full content button
          if (isTruncated) {
            const showFullButton = resultsDiv.querySelector('.show-full-content');
            showFullButton.addEventListener('click', (e) => {
              const fullContent = decodeURIComponent(e.target.dataset.fullContent);
              const contentPre = resultsDiv.querySelector('.tool-result-content');
              contentPre.textContent = fullContent;
              e.target.style.display = 'none';
            });
          }
        }
      }
    }
  }

  // AI Status Management - Using Tailwind Classes
  updateAIStatus(status, message = null) {
    if (!this.aiStatus) return;

    // Reset to base classes
    this.aiStatus.className = 'text-xs font-normal px-2 py-1 rounded text-center min-w-20';

    switch (status) {
      case 'ready':
        this.aiStatus.textContent = 'Ready';
        this.aiStatus.classList.add('bg-green-600', 'text-white');
        this.stopButton.disabled = true;
        break;
      case 'thinking':
        this.aiStatus.textContent = 'Thinking...';
        this.aiStatus.classList.add('bg-orange-500', 'text-white', 'animate-pulse-custom');
        this.stopButton.disabled = false;
        break;
      case 'working':
        this.aiStatus.textContent = message || 'Working...';
        this.aiStatus.classList.add('bg-blue-500', 'text-white', 'animate-pulse-custom');
        this.stopButton.disabled = false;
        break;
      case 'stopped':
        this.aiStatus.textContent = 'Stopped';
        this.aiStatus.classList.add('bg-red-600', 'text-white');
        this.stopButton.disabled = true;
        break;
    }
  }

  stopAI() {
    if (!this.isConnected) return;

    // Send stop signal to backend
    const stopMessage = {
      type: 'stop_ai',
      timestamp: new Date().toISOString()
    };

    this.socket.send(JSON.stringify(stopMessage));

    // Update UI immediately
    this.updateAIStatus('stopped');
    this.hideTypingIndicator(); // Clear any typing indicator
    this.finishStreamingMessage(); // Clean up any streaming message
    this.pendingStreamModel = null; // Clean up pending stream

    // Clear tool timeout if active
    if (this.toolTimeout) {
      clearTimeout(this.toolTimeout);
      this.toolTimeout = null;
    }

    this.chatInput.disabled = false;
    this.chatSend.disabled = false;

    // Add system message
    this.addSystemMessage('AI execution stopped by user', 'stopped');
  }

  // Override sendMessage to update status
  sendMessage() {
    const message = this.chatInput.value.trim();
    if (!message || !this.isConnected) return;

    // Add user message to chat
    this.addMessage(message, 'user');
    this.chatInput.value = '';
    this.adjustInputHeight();

    // Disable input while processing
    this.chatInput.disabled = true;
    this.chatSend.disabled = true;

    // Update AI status
    this.updateAIStatus('thinking');

    // Show typing indicator
    this.showTypingIndicator();

    // Send message to WebSocket
    const messageData = {
      type: 'chat_message',
      content: message
    };

    this.socket.send(JSON.stringify(messageData));
  }

  // Override handleWebSocketMessage to handle status updates
  handleWebSocketMessage(data) {
    try {
      const message = JSON.parse(data);

      // Debug: Log all incoming messages
      console.log('=== Incoming WebSocket Message ===');
      console.log('Type:', message.type);
      if (message.content) {
        console.log('Content length:', message.content.length);
        console.log('Content preview:', JSON.stringify(message.content.substring(0, 300)));
      }
      console.log('=================================');

      switch (message.type) {
        case 'system':
          // Only show system messages that aren't connection-related
          if (!message.content.includes('connected') && !message.content.includes('Chat system')) {
            this.addSystemMessage(message.content, 'connected');
          }
          break;

        case 'stream_start':
          console.log('Stream started');
          this.hideTypingIndicator();
          // Don't create streaming message yet - wait for first content chunk
          this.streamingContent = "";
          this.thinkingContent = "";
          this.pendingStreamModel = message.model;
          break;

        case 'stream_chunk':
          // Hide typing indicator on first chunk if still showing
          if (this.isTyping) {
            this.hideTypingIndicator();
          }
          if (message.content) {
            // Create streaming message div only when we have actual content
            if (!this.streamingMessage) {
              this.startStreamingMessage(this.pendingStreamModel);
            }

            // Check if this is a thinking chunk (role === "thinking")
            if (message.role === 'thinking') {
              this.appendToThinkingMessage(message.content);
            } else {
              this.appendToStreamingMessage(message.content);
            }
          }
          break;

        case 'stream_end':
          console.log('Stream ended:', message.reason);
          this.finishStreamingMessage();
          this.updateAIStatus('ready');
          this.chatInput.disabled = false;
          this.chatSend.disabled = false;
          this.chatInput.focus();
          break;

        case 'stream_error':
          console.error('Stream error:', message.error);
          this.finishStreamingMessage();
          this.addErrorMessage(`Streaming error: ${message.error}`);
          this.updateAIStatus('ready');
          this.chatInput.disabled = false;
          this.chatSend.disabled = false;
          break;

        case 'ai_message':
          // Fallback for non-streaming responses
          this.hideTypingIndicator();
          this.addMessage(message.content, 'ai', message.model);
          this.updateAIStatus('ready');
          this.chatInput.disabled = false;
          this.chatSend.disabled = false;
          this.chatInput.focus();
          break;

        case 'tool_usage':
          this.updateAIStatus('working', `Using ${message.content}`);
          this.addToolUsageMessage(message);

          // Set a timeout in case tool execution hangs or fails to report completion
          // Clear any existing tool timeout
          if (this.toolTimeout) {
            clearTimeout(this.toolTimeout);
          }

          // Set 30-second timeout for tool execution
          this.toolTimeout = setTimeout(() => {
            console.warn('Tool execution timeout - returning to ready state');
            this.updateAIStatus('ready');
            this.chatInput.disabled = false;
            this.chatSend.disabled = false;
            this.toolTimeout = null;
          }, 30000);
          break;

        case 'tool_result':
          this.updateToolResult(message);

          // Clear tool timeout since we got a result
          if (this.toolTimeout) {
            clearTimeout(this.toolTimeout);
            this.toolTimeout = null;
          }

          // Tool execution complete, update status back to ready
          this.updateAIStatus('ready');
          this.chatInput.disabled = false;
          this.chatSend.disabled = false;
          break;

        case 'typing':
          // Server is processing - show typing indicator
          this.showTypingIndicator();
          break;

        case 'ai_status':
          // Handle specific AI status updates from backend
          this.updateAIStatus(message.status, message.message);
          break;

        case 'error':
          this.hideTypingIndicator();
          this.addErrorMessage(message.content);
          this.updateAIStatus('ready');
          this.chatInput.disabled = false;
          this.chatSend.disabled = false;
          break;

        case 'pong':
          // Handle pong response
          break;

        default:
          console.warn('Unknown message type:', message.type);
      }
    } catch (error) {
      console.error('Error parsing WebSocket message:', error);
    }
  }

  generateWebContentSummary(resultContent) {
    if (resultContent.url) {
      const domain = new URL(resultContent.url).hostname;
      const contentLength = resultContent.content ? resultContent.content.length : 0;
      return `📄 Extracted content from ${domain} (${contentLength} characters)`;
    }
    return 'Web content extracted';
  }

  formatSearchResults(resultContent) {
    if (resultContent.results && typeof resultContent.results === 'string') {
      // If results is a markdown string, show it directly
      return resultContent.results;
    } else if (resultContent.results && Array.isArray(resultContent.results)) {
      // If results is an array, format it nicely
      return resultContent.results.map((result, index) =>
        `${index + 1}. ${result.title || result.url || result}`
      ).join('\n');
    }
    return JSON.stringify(resultContent, null, 2);
  }
}

// Initialize chat when DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
  window.chatManager = new ChatManager();
});

// Global functions for debugging
window.clearChat = () => window.chatManager?.clearChat();
window.exportChat = () => window.chatManager?.exportChat();
