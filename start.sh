#!/bin/bash

# Add your OpenRouter API key here
# Default API key is only given for easy access to free models. You should create your own key for better privacy and security.
export OPENROUTER_API_KEY="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"

# Ensure OPENROUTER_API_KEY is set before continuing
if [ -z "${OPENROUTER_API_KEY}" ]; then
  echo "❌ OPENROUTER_API_KEY is not set. Please set it in start.sh or export it in your environment."
  exit 1
fi

# Uncomment and set your preferred model
# export LLM_MODEL="gpt-4-turbo"
# export LLM_MODEL="claude-3-opus"
# export LLM_MODEL="x-ai/grok-4-fast"
export LLM_MODEL="minimax/minimax-m2:free"

# Start the application
echo "🧹 Clearing logs folder..."
rm -rf logs/*
echo "✅ Logs folder cleared."

echo "🔑 API keys are loaded"
echo "🤖 Active LLM model: ${LLM_MODEL}" 
echo "🚀 Starting the Elixir application..."
echo "."
mix run --no-halt