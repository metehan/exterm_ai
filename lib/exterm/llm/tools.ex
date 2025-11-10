defmodule Exterm.Llm.Tools do
  @moduledoc """
  AI tools coordinator that delegates to specialized modules.
  AI can suggest commands but user must approve them.
  """

  alias Exterm.Llm.Tools.Terminal
  alias Exterm.Llm.Tools.File
  alias Exterm.Llm.Tools.Web
  alias Exterm.Llm.Tools.ChatSummary

  @tools [
    # Terminal tools
    %{
      "type" => "function",
      "function" => %{
        "name" => "read_terminal",
        "description" =>
          "Read the current terminal output and recent command history to understand what's happening in the terminal",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "lines" => %{
              "type" => "integer",
              "description" => "Number of recent output lines to read (default: 20, max: 100)"
            }
          }
        }
      }
    },
    %{
      "type" => "function",
      "function" => %{
        "name" => "send_to_terminal",
        "description" =>
          "Send a command or input directly to the terminal. By default, waits for completion and returns results automatically.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "input" => %{
              "type" => "string",
              "description" =>
                "The text/command to send to the terminal (e.g., 'ls -la', 'cd /home', 'exit')"
            },
            "add_newline" => %{
              "type" => "boolean",
              "description" =>
                "Whether to add a newline (Enter) after the input (default: true for commands)"
            },
            "auto_read" => %{
              "type" => "boolean",
              "description" =>
                "Whether to automatically wait and read terminal output after sending command (default: true)"
            },
            "sleep_seconds" => %{
              "type" => "number",
              "description" =>
                "How long to wait before reading results when auto_read is true (default: 1.5 seconds)"
            }
          },
          "required" => ["input"]
        }
      }
    },
    %{
      "type" => "function",
      "function" => %{
        "name" => "sleep",
        "description" =>
          "Wait for a specified amount of time. Useful for waiting for terminal commands to complete before reading output.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "seconds" => %{
              "type" => "number",
              "description" => "Number of seconds to wait (can be decimal, e.g., 0.5 for 500ms)"
            }
          },
          "required" => ["seconds"]
        }
      }
    },
    %{
      "type" => "function",
      "function" => %{
        "name" => "suggest_terminal_command",
        "description" =>
          "Suggest a terminal command for user approval. The command will not be executed immediately - user must approve it first.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "command" => %{
              "type" => "string",
              "description" =>
                "The command to suggest (e.g., 'ls -la', 'pwd', 'cat filename.txt')"
            },
            "reason" => %{
              "type" => "string",
              "description" => "Explanation of why this command would be helpful"
            }
          },
          "required" => ["command", "reason"]
        }
      }
    },
    %{
      "type" => "function",
      "function" => %{
        "name" => "get_terminal_history",
        "description" => "Get recent terminal command history and outputs for context",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "lines" => %{
              "type" => "integer",
              "description" => "Number of recent entries to retrieve (default: 20, max: 50)"
            }
          }
        }
      }
    },
    # File tools
    %{
      "type" => "function",
      "function" => %{
        "name" => "create_file",
        "description" =>
          "Create a new file with specified content. Use this instead of interactive editors like nano/vim.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "File path (relative to current directory or absolute)"
            },
            "content" => %{
              "type" => "string",
              "description" => "File content to write"
            }
          },
          "required" => ["path", "content"]
        }
      }
    },
    %{
      "type" => "function",
      "function" => %{
        "name" => "read_file",
        "description" =>
          "Read content from a file. Useful for examining configuration files, logs, or code.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "File path (relative to current directory or absolute)"
            },
            "lines" => %{
              "type" => "integer",
              "description" => "Number of lines to read (default: all, max: 1000)"
            },
            "start_line" => %{
              "type" => "integer",
              "description" => "Starting line number (1-based, default: 1)"
            }
          },
          "required" => ["path"]
        }
      }
    },
    %{
      "type" => "function",
      "function" => %{
        "name" => "update_file",
        "description" =>
          "Update/overwrite an existing file with new content. Creates the file if it doesn't exist.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "File path (relative to current directory or absolute)"
            },
            "content" => %{
              "type" => "string",
              "description" => "New file content"
            }
          },
          "required" => ["path", "content"]
        }
      }
    },
    %{
      "type" => "function",
      "function" => %{
        "name" => "append_to_file",
        "description" => "Append content to the end of an existing file",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "File path (relative to current directory or absolute)"
            },
            "content" => %{
              "type" => "string",
              "description" => "Content to append"
            }
          },
          "required" => ["path", "content"]
        }
      }
    },
    %{
      "type" => "function",
      "function" => %{
        "name" => "delete_file",
        "description" => "Delete a file from the filesystem",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "File path (relative to current directory or absolute)"
            }
          },
          "required" => ["path"]
        }
      }
    },
    %{
      "type" => "function",
      "function" => %{
        "name" => "find_and_replace_in_file",
        "description" =>
          "Find and replace text in a file using literal string matching. Safer than regex for exact replacements.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "File path (relative to current directory or absolute)"
            },
            "search_text" => %{
              "type" => "string",
              "description" => "Exact text to find and replace (literal match)"
            },
            "replace_text" => %{
              "type" => "string",
              "description" => "Text to replace it with"
            },
            "max_replacements" => %{
              "type" => "integer",
              "description" => "Maximum number of replacements to make (default: all)"
            }
          },
          "required" => ["path", "search_text", "replace_text"]
        }
      }
    },
    %{
      "type" => "function",
      "function" => %{
        "name" => "list_files",
        "description" => "List files and directories in a specified path",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "Directory path to list (default: current directory)"
            },
            "recursive" => %{
              "type" => "boolean",
              "description" => "Whether to list files recursively (default: false)"
            },
            "max_depth" => %{
              "type" => "integer",
              "description" => "Maximum depth for recursive listing (default: 3)"
            },
            "show_hidden" => %{
              "type" => "boolean",
              "description" => "Whether to show hidden files (default: false)"
            }
          }
        }
      }
    },
    # Web tools
    %{
      "type" => "function",
      "function" => %{
        "name" => "browse_web",
        "description" =>
          "Browse a web page and extract readable content. Returns the main text content in markdown format.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "url" => %{
              "type" => "string",
              "description" => "URL to browse (with or without http/https prefix)"
            },
            "max_content_length" => %{
              "type" => "integer",
              "description" => "Maximum length of content to return (default: 8000, max: 20000)"
            }
          },
          "required" => ["url"]
        }
      }
    },
    %{
      "type" => "function",
      "function" => %{
        "name" => "search_web",
        "description" =>
          "Search the web using DuckDuckGo and return a list of relevant results with titles, URLs, and snippets.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{
              "type" => "string",
              "description" => "Search query (e.g., 'how to install Node.js on Ubuntu')"
            },
            "max_results" => %{
              "type" => "integer",
              "description" => "Maximum number of results to return (default: 5, max: 10)"
            }
          },
          "required" => ["query"]
        }
      }
    },
    # Chat management tools
    %{
      "type" => "function",
      "function" => %{
        "name" => "summarize_chat",
        "description" =>
          "Summarize the current chat history to condense it when it becomes too long or when switching topics. This helps maintain context while reducing memory usage.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "reason" => %{
              "type" => "string",
              "description" =>
                "Reason for summarization: 'topic_change', 'automatic_length_limit', 'user_request', or 'custom'",
              "enum" => ["topic_change", "automatic_length_limit", "user_request", "custom"]
            },
            "max_history_length" => %{
              "type" => "integer",
              "description" =>
                "Number of recent messages to keep after summarization (default: 10)"
            },
            "summary_length" => %{
              "type" => "string",
              "description" =>
                "Length of summary: 'short', 'medium', or 'long' (default: 'medium')",
              "enum" => ["short", "medium", "long"]
            }
          },
          "required" => ["reason"]
        }
      }
    }
  ]

  def get_tools, do: @tools

  @doc """
  Execute a tool function call from the AI
  """
  # Terminal tools delegation
  def execute_tool("read_terminal", params, chat_socket_pid) do
    Terminal.read_terminal(params, chat_socket_pid)
  end

  def execute_tool("send_to_terminal", params, chat_socket_pid) do
    Terminal.send_to_terminal(params, chat_socket_pid)
  end

  def execute_tool("sleep", params, chat_socket_pid) do
    Terminal.sleep(params, chat_socket_pid)
  end

  def execute_tool("suggest_terminal_command", params, chat_socket_pid) do
    Terminal.suggest_terminal_command(params, chat_socket_pid)
  end

  def execute_tool("get_terminal_history", params, chat_socket_pid) do
    Terminal.get_terminal_history(params, chat_socket_pid)
  end

  # File tools delegation
  def execute_tool("create_file", params, chat_socket_pid) do
    File.create_file(params, chat_socket_pid)
  end

  def execute_tool("read_file", params, chat_socket_pid) do
    File.read_file(params, chat_socket_pid)
  end

  def execute_tool("update_file", params, chat_socket_pid) do
    File.update_file(params, chat_socket_pid)
  end

  def execute_tool("append_to_file", params, chat_socket_pid) do
    File.append_to_file(params, chat_socket_pid)
  end

  def execute_tool("delete_file", params, chat_socket_pid) do
    File.delete_file(params, chat_socket_pid)
  end

  def execute_tool("find_and_replace_in_file", params, chat_socket_pid) do
    File.find_and_replace_in_file(params, chat_socket_pid)
  end

  def execute_tool("list_files", params, chat_socket_pid) do
    File.list_files(params, chat_socket_pid)
  end

  # Web tools delegation
  def execute_tool("browse_web", params, chat_socket_pid) do
    Web.browse_web(params, chat_socket_pid)
  end

  def execute_tool("search_web", params, chat_socket_pid) do
    Web.search_web(params, chat_socket_pid)
  end

  # Chat management tools delegation
  def execute_tool("summarize_chat", params, _chat_socket_pid) do
    # The chat_pid is the current process since tools are executed within the Chat GenServer
    chat_pid = self()

    ChatSummary.summarize_chat_with_pid(
      chat_pid,
      Map.get(params, "reason", "user_request"),
      Map.get(params, "max_history_length", 10),
      Map.get(params, "summary_length", "medium")
    )
  end

  # Fallback for unknown tools (3-parameter version)
  def execute_tool(tool_name, _params, _chat_socket_pid) do
    %{
      "success" => false,
      "error" => "Unknown tool: #{tool_name}"
    }
  end

  # Special case for summarize_chat with direct messages to avoid deadlock (4-parameter version)
  def execute_tool("summarize_chat", params, _chat_socket_pid, messages) do
    ChatSummary.summarize_chat_with_messages(
      messages,
      Map.get(params, "reason", "user_request"),
      Map.get(params, "max_history_length", 10),
      Map.get(params, "summary_length", "medium")
    )
  end

  # Fallback for unknown tools (4-parameter version)
  def execute_tool(tool_name, _params, _chat_socket_pid, _extra) do
    %{
      "success" => false,
      "error" => "Unknown tool: #{tool_name}"
    }
  end
end
