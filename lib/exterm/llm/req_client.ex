defmodule Exterm.Llm.ReqClient do
  @moduledoc """
  ReqLLM-based client that provides the same API as our old Client module.
  Wraps ReqLLM library to maintain backward compatibility with existing code.
  """

  @providers %{
    groq: %{
      default_model: "gemma2-9b-it"
    },
    deepinfra: %{
      default_model: "google/gemma-3-4b-it"
    },
    openrouter: %{
      default_model: "qwen/qwen3-235b-a22b:free"
    }
  }

  @doc """
  Sends a chat request (non-streaming).

  ## Options (same as old client)
    - :model - Model ID
    - :temperature - Sampling temperature
    - :max_tokens - Max tokens in response
    - :previous_messages - List of previous messages
    - :functions - List of function/tool definitions
  """
  def chat(provider, prompt, opts \\ []) when is_atom(provider) and is_binary(prompt) do
    # Get model from opts or use default
    config = @providers[provider]

    unless config do
      raise ArgumentError,
            "Unknown provider: #{provider}. Available providers: #{Map.keys(@providers) |> Enum.join(", ")}"
    end

    model = Keyword.get(opts, :model, config.default_model)

    # Build model spec for ReqLLM
    model_spec = "#{provider}:#{model}"

    # Extract options
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 2048)
    previous_messages = Keyword.get(opts, :previous_messages, [])
    functions = Keyword.get(opts, :functions, nil)

    # Build messages list (ReqLLM accepts our format!)
    messages = previous_messages ++ [%{role: "user", content: prompt}]

    # Build ReqLLM options
    req_opts = [
      temperature: temperature,
      max_tokens: max_tokens
    ]

    # Add tools if provided (try OpenAI format first)
    req_opts =
      if functions do
        req_opts
        |> Keyword.put(:tools, functions)
        # CRITICAL: For Claude via OpenRouter, tool_choice is REQUIRED
        # Without this, Claude treats tools as documentation only and hallucinates usage
        |> Keyword.put(:tool_choice, "auto")
      else
        req_opts
      end

    # Get API key from environment
    api_key = get_api_key(provider)
    req_opts = if api_key, do: Keyword.put(req_opts, :api_key, api_key), else: req_opts

    # Call ReqLLM
    case ReqLLM.generate_text(model_spec, messages, req_opts) do
      {:ok, response} ->
        # Transform to match old format (return map directly, not wrapped in tuple)
        transform_response(response)

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Streams chat completions.

  Returns a Stream that emits chunks compatible with our current format.

  NOTE: When tools are provided, uses direct HTTPoison streaming instead of ReqLLM
  because ReqLLM doesn't properly parse tool_call chunks from OpenRouter's SSE stream.
  """
  def stream_chat(provider, prompt, opts \\ []) when is_atom(provider) and is_binary(prompt) do
    functions = Keyword.get(opts, :functions, nil)
    previous_messages = Keyword.get(opts, :previous_messages, [])

    # Check if message history contains "tool" role messages
    has_tool_messages =
      Enum.any?(previous_messages, fn msg ->
        Map.get(msg, :role) == "tool" || Map.get(msg, "role") == "tool"
      end)

    # If tools are present OR history has tool messages, use direct HTTP streaming
    # ReqLLM has issues with both tool call parsing AND tool role messages
    if (functions && length(functions) > 0) || has_tool_messages do
      reason = if has_tool_messages, do: "tool role messages in history", else: "tools present"
      IO.puts("ReqClient: Using direct HTTP streaming (#{reason})")

      stream_chat_with_http(provider, prompt, opts)
    else
      stream_chat_with_reqllm(provider, prompt, opts)
    end
  end

  defp stream_chat_with_reqllm(provider, prompt, opts) do
    # Get model from opts or use default
    config = @providers[provider]

    unless config do
      raise ArgumentError,
            "Unknown provider: #{provider}. Available providers: #{Map.keys(@providers) |> Enum.join(", ")}"
    end

    model = Keyword.get(opts, :model, config.default_model)

    # Build model spec for ReqLLM
    model_spec = "#{provider}:#{model}"

    # Extract options
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 2048)
    previous_messages = Keyword.get(opts, :previous_messages, [])
    functions = Keyword.get(opts, :functions, nil)

    # Build messages list
    messages = previous_messages ++ [%{role: "user", content: prompt}]

    # Build ReqLLM options
    req_opts = [
      temperature: temperature,
      max_tokens: max_tokens
    ]

    # Add tools if provided
    req_opts =
      if functions do
        req_opts
        |> Keyword.put(:tools, functions)
        # CRITICAL: For OpenRouter, tool_choice is REQUIRED for reliable tool calling
        # Without this, models treat tools as documentation only
        # NOTE: Even with this, some models via OpenRouter may not call tools reliably
        # Consider adding explicit instructions in system prompt to use tools
        |> Keyword.put(:tool_choice, "auto")
      else
        req_opts
      end

    # Get API key
    api_key = get_api_key(provider)
    req_opts = if api_key, do: Keyword.put(req_opts, :api_key, api_key), else: req_opts

    # Call ReqLLM streaming
    case ReqLLM.stream_text(model_spec, messages, req_opts) do
      {:ok, stream_response} ->
        # Return the transformed stream
        # The stream_response also contains tool call info that can be extracted after streaming
        transform_stream(stream_response)

      {:error, reason} ->
        IO.puts("ReqClient: Stream error: #{inspect(reason)}")
        # Return empty stream on error
        Stream.map([], fn _ -> nil end)
    end
  end

  defp get_api_key(provider) do
    case provider do
      :openrouter -> System.get_env("OPENROUTER_API_KEY")
      :groq -> System.get_env("GROQ_API_KEY")
      :deepinfra -> System.get_env("DEEPINFRA_API_KEY")
    end
  end

  defp transform_response(response) do
    # ReqLLM.Response -> Old format
    # Old format: %{"choices" => [%{"message" => %{"content" => "...", "tool_calls" => [...]}}]}

    content = ReqLLM.Response.text(response)

    # Get tool_calls from message if present
    tool_calls =
      if response.message && Map.has_key?(response.message, :tool_calls) do
        response.message.tool_calls || []
      else
        []
      end

    %{
      "choices" => [
        %{
          "message" => %{
            "content" => content,
            "role" => "assistant",
            "tool_calls" => format_tool_calls(tool_calls)
          }
        }
      ]
    }
  end

  defp format_tool_calls([]), do: nil

  defp format_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tool_call ->
      %{
        "id" => tool_call.id || generate_tool_call_id(),
        "type" => "function",
        "function" => %{
          "name" => tool_call.name,
          "arguments" => Jason.encode!(tool_call.arguments)
        }
      }
    end)
  end

  defp transform_stream(stream_response) do
    # Transform ReqLLM.StreamResponse to our old format
    stream_response.stream
    |> Stream.map(fn chunk ->
      # Simple pass-through: just convert chunk type to our format
      case chunk.type do
        :content when chunk.text not in [nil, ""] ->
          %{
            "choices" => [
              %{
                "delta" => %{"content" => chunk.text}
              }
            ]
          }

        :thinking when chunk.text not in [nil, ""] ->
          %{
            "choices" => [
              %{
                "delta" => %{
                  "content" => chunk.text,
                  "role" => "thinking"
                }
              }
            ]
          }

        :tool_call ->
          # Convert arguments to JSON string if it's a map
          args_json =
            case chunk.arguments do
              args when is_map(args) -> Jason.encode!(args)
              args when is_binary(args) -> args
              nil -> "{}"
              _ -> "{}"
            end

          %{
            "choices" => [
              %{
                "delta" => %{
                  "tool_calls" => [
                    %{
                      "index" => 0,
                      "id" => generate_tool_call_id(),
                      "type" => "function",
                      "function" => %{
                        "name" => chunk.name,
                        "arguments" => args_json
                      }
                    }
                  ]
                }
              }
            ]
          }

        :meta ->
          # Check if it's a finish_reason meta chunk
          if Map.has_key?(chunk.metadata, :finish_reason) do
            %{
              "choices" => [
                %{
                  "finish_reason" => chunk.metadata.finish_reason
                }
              ]
            }
          else
            nil
          end

        _ ->
          nil
      end
    end)
    |> Stream.reject(&is_nil/1)
  end

  defp generate_tool_call_id do
    "call_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
  end

  # Direct HTTP streaming when tools are present (ReqLLM doesn't parse tool calls properly)
  defp stream_chat_with_http(provider, prompt, opts) do
    config = @providers[provider]

    model = Keyword.get(opts, :model, config.default_model)
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 2048)
    previous_messages = Keyword.get(opts, :previous_messages, [])
    functions = Keyword.get(opts, :functions, [])

    messages = previous_messages ++ [%{role: "user", content: prompt}]

    api_key = get_api_key(provider)
    unless api_key, do: raise(ArgumentError, "API key not found for #{provider}")

    # Build OpenRouter URL
    url =
      case provider do
        :openrouter -> "https://openrouter.ai/api/v1/chat/completions"
        :groq -> "https://api.groq.com/openai/v1/chat/completions"
        :deepinfra -> "https://api.deepinfra.com/v1/openai/chat/completions"
      end

    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{api_key}"},
      {"Accept", "text/event-stream"}
    ]

    # Build request body - only include tools if present
    base_body = %{
      model: model,
      messages: messages,
      temperature: temperature,
      max_tokens: max_tokens,
      stream: true
    }

    body =
      if functions && length(functions) > 0 do
        Map.put(base_body, :tools, functions)
      else
        base_body
      end
      |> Jason.encode!()

    # Return a stream using HTTPoison (same as old client)
    Stream.resource(
      fn ->
        case HTTPoison.post(url, body, headers,
               stream_to: self(),
               async: :once,
               recv_timeout: 60_000
             ) do
          {:ok, %HTTPoison.AsyncResponse{id: id}} ->
            id

          {:error, _error} ->
            nil
        end
      end,
      fn
        nil ->
          {:halt, nil}

        id ->
          receive do
            %HTTPoison.AsyncStatus{id: ^id} ->
              HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})
              {[], id}

            %HTTPoison.AsyncHeaders{id: ^id} ->
              HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})
              {[], id}

            %HTTPoison.AsyncChunk{id: ^id, chunk: chunk} ->
              HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})
              parsed_chunks = parse_sse_chunk(chunk)
              {parsed_chunks, id}

            %HTTPoison.AsyncEnd{id: ^id} ->
              {:halt, nil}

            %HTTPoison.Error{id: ^id} ->
              {:halt, nil}
          after
            60_000 ->
              {:halt, nil}
          end
      end,
      fn _ -> :ok end
    )
  end

  defp parse_sse_chunk(chunk) do
    chunk
    |> String.split("
")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(fn line ->
      data = String.replace_prefix(line, "data: ", "")

      case String.trim(data) do
        "[DONE]" ->
          %{"choices" => [%{"finish_reason" => "stop"}]}

        "" ->
          nil

        json ->
          case Jason.decode(json) do
            {:ok, parsed} -> parsed
            {:error, _} -> nil
          end
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end
