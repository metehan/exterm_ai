# Elixir Web Terminal with AI Assistant

An advanced web-based terminal emulator with built-in AI assistance powered by OpenRouter. This project combines a real terminal in the browser with intelligent AI capabilities, allowing users to get help, analyze outputs, and receive command suggestions.

## Screenshot

![Elixir Web Terminal](priv/static/elixir_web_terminal.png)

## How It Works

### Core Architecture

**exterm** is an Elixir application that:

1. **Serves a Web Terminal** - A responsive browser-based terminal using xterm.js for shell interaction.
2. **Manages AI Conversations** - Maintains conversation history and context using WebSockets.
3. **Integrates OpenRouter API** - Connects to multiple AI models through OpenRouter for intelligent assistance.
4. **Streams AI Responses** - Streams AI completions to the browser in real time.
5. **Executes Tools** - The AI can search the web, browse pages, and analyze terminal output.

### AI Features

- **Terminal Analysis** - Ask the AI to explain terminal output or diagnose issues.
- **Command Suggestions** - Get help finding the right command for a task.
- **Web Research** - AI can search and browse the web to find current information.
- **Interactive Assistance** - Multi-turn conversations with full context awareness.
- **Tool Execution** - The AI can run tools (search_web, browse_web, etc.) to answer questions comprehensively.

## Project Structure

```
exterm
├── lib
│   ├── exterm
│   │   ├── application.ex
│   │   ├── router.ex
│   │   ├── chat_socket.ex          # WebSocket handler for AI chat
│   │   ├── llm                     # AI/LLM integration
│   │   │   ├── client.ex           # OpenRouter API client
│   │   │   └── chat.ex             # Chat state management
│   │   ├── terminal
│   │   │   ├── pty.ex              # PTY management
│   │   │   └── handler.ex          # Terminal I/O
│   │   └── tools                   # Tool implementations
│   │       ├── web_search.ex
│   │       ├── web_browse.ex
│   │       └── ...
│   └── exterm.ex
├── priv
│   └── static
│       ├── index.html
│       ├── chat.js                 # AI chat interface
│       ├── terminal.js             # Terminal interaction
│       ├── xterm.css
│       └── xterm.js
├── config
│   └── config.exs
├── start.sh                        # Quick start script
├── mix.exs
└── README.md
```

## Quick Start

### Prerequisites

- Elixir 1.14+ and Erlang/OTP 25+
- An OpenRouter API key (get one free at https://openrouter.ai)

### Installation & Setup

1. **Clone the repository**:
   ```bash
   git clone https://github.com/yourusername/exterm.git
   cd exterm
   ```

2. **Get dependencies**:
   ```bash
   mix deps.get
   ```

3. **Run the application**:
   ```bash
   ./start.sh
   ```

4. **Open in browser**:
   Navigate to `http://localhost:4000`

## Configuration

The application reads configuration from environment variables:

- `OPENROUTER_API_KEY` - Your OpenRouter API key (required for AI features)
- `PORT` - Server port (default: 4000)
- `HOST` - Server host (default: localhost)

Example configuration in `start.sh`:
```bash
export OPENROUTER_API_KEY="sk-or-v1-..."
export PORT=4000
mix run --no-halt
```

## Usage Examples

### Terminal
- Execute shell commands as you normally would
- Get real-time output in the browser

### AI Assistance
- Ask: "What does this error mean?"
- Ask: "How do I list all running processes?"
- Ask: "Search for the latest Node.js documentation"

The AI will:
1. Analyze your question and context
2. Execute tools if needed (search, browse)
3. Provide comprehensive answers
4. Suggest next steps when appropriate

## Features

- **WebSocket Communication** - Real-time bidirectional communication between browser and server.
- **Terminal Interface** - Full xterm.js terminal emulation with proper PTY handling.
- **AI Integration** - Multi-model support through OpenRouter (GPT-4, Claude, Grok, etc.).
- **Stream Processing** - Efficient streaming of large AI responses.
- **Tool Execution** - Web search, web browsing, and more.
- **Session Management** - Persistent chat context per terminal session.
- **Error Handling** - Comprehensive error management and recovery.

## API Keys

### OpenRouter models and API Key

Through OpenRouter, you have access to many models. I've included my own key with no balance so you can access some free models without creating your own key. However, free model providers often use your data and history to train their models. It's better to create your own API key.

1. Visit [OpenRouter](https://openrouter.ai)
2. Sign up for a free account
3. Go to Settings → API Keys
4. Create a new API key
5. Copy it and add it to your `start.sh`

## Future plans

This tool is planned to become a full-fledged orchestration tool that can run AI agents in the background.

Upcoming:
- RAG
- Long-term memory
- Multiple AI personas
- Work with MCPs
- Orchestration