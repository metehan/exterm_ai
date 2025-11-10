defmodule Exterm.Llm.Client do
  @moduledoc """
  Unified client for OpenAI-compatible LLM APIs (Groq, DeepInfra)
  """

  @providers %{
    groq: %{
      url: "https://api.groq.com/openai/v1/chat/completions",
      api_key_env: "GROQ_API_KEY",
      default_model: "gemma2-9b-it"
    },
    deepinfra: %{
      url: "https://api.deepinfra.com/v1/openai/chat/completions",
      api_key_env: "DEEPINFRA_API_KEY",
      default_model: "google/gemma-3-4b-it"
    },
    openrouter: %{
      url: "https://openrouter.ai/api/v1/chat/completions",
      api_key_env: "OPENROUTER_API_KEY",
      default_model: "qwen/qwen3-235b-a22b:free"
    }
  }

  @doc """
  Sends a prompt to specified LLM provider and returns the response.

  ## Options
    - `:model` - Model ID (defaults to provider's default model)
    - `:temperature` - Sampling temperature, default is 0.7
    - `:max_tokens` - Max number of tokens in response, default is 2048
    - `:previous_messages` - List of previous messages in the conversation
    - `:functions` - List of function definitions for function calling
  """
  def chat(provider, prompt, opts \\ []) when is_atom(provider) and is_binary(prompt) do
    config = @providers[provider]

    unless config do
      raise ArgumentError,
            "Unknown provider: #{provider}. Available providers: #{Map.keys(@providers) |> Enum.join(", ")}"
    end

    model = Keyword.get(opts, :model, config.default_model)
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 2048)
    previous_messages = Keyword.get(opts, :previous_messages, [])
    functions = Keyword.get(opts, :functions, nil)

    # Build messages from previous messages plus the current prompt
    messages = previous_messages ++ [%{role: "user", content: prompt}]

    # Get API key at runtime
    api_key = System.get_env(config.api_key_env)

    unless api_key do
      raise ArgumentError, "API key not found in environment variable: #{config.api_key_env}"
    end

    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{api_key}"}
    ]

    body =
      %{
        model: model,
        messages: messages,
        temperature: temperature,
        max_tokens: max_tokens
        # response_format: %{type: "json_object"}
      }

    body_with_functions = maybe_add_functions(body, functions)

    encoded_body = Jason.encode!(body_with_functions)

    case HTTPoison.post(config.url, encoded_body, headers, recv_timeout: 30_000) do
      {:ok, %{status_code: 200, body: response_body}} ->
        response_body |> Jason.decode!()

      {:ok, %{status_code: code, body: body}} ->
        {:error, {:http_error, code, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Streams chat completions from the specified provider.

  ## Options same as chat/3
  """
  def stream_chat(provider, prompt, opts \\ []) when is_atom(provider) and is_binary(prompt) do
    config = @providers[provider]

    unless config do
      raise ArgumentError,
            "Unknown provider: #{provider}. Available providers: #{Map.keys(@providers) |> Enum.join(", ")}"
    end

    model = Keyword.get(opts, :model, config.default_model)
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 2048)
    previous_messages = Keyword.get(opts, :previous_messages, [])
    functions = Keyword.get(opts, :functions, nil)

    messages =
      if provider == :groq do
        [
          # %{role: "system", content: "You must respond in valid JSON format."},
          # %{role: "user", content: "Respond in JSON format. " <> prompt}
        ]
      else
        [%{role: "user", content: prompt}]
      end

    messages = previous_messages ++ messages

    # Get API key at runtime
    api_key = System.get_env(config.api_key_env)

    unless api_key do
      raise ArgumentError, "API key not found in environment variable: #{config.api_key_env}"
    end

    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{api_key}"},
      {"Accept", "text/event-stream"}
    ]

    body =
      %{
        model: model,
        messages: messages,
        temperature: temperature,
        max_tokens: max_tokens,
        stream: true
      }
      |> maybe_add_functions(functions)
      |> Jason.encode!()

    # Create a simple stream that collects chunks
    Stream.resource(
      fn ->
        IO.puts("Starting HTTP request for streaming...")

        case HTTPoison.post(config.url, body, headers,
               stream_to: self(),
               async: :once,
               recv_timeout: 60_000
             ) do
          {:ok, %HTTPoison.AsyncResponse{id: id}} ->
            IO.puts("Got async response ID: #{inspect(id)}")
            id

          {:error, error} ->
            IO.puts("HTTP request failed: #{inspect(error)}")
            nil
        end
      end,
      fn
        nil ->
          {:halt, nil}

        id ->
          receive do
            %HTTPoison.AsyncStatus{id: ^id, code: _code} ->
              HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})
              {[], id}

            %HTTPoison.AsyncHeaders{id: ^id, headers: _headers} ->
              HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})
              {[], id}

            %HTTPoison.AsyncChunk{id: ^id, chunk: chunk} ->
              HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})

              parsed_chunks = parse_sse_chunk(chunk)

              if length(parsed_chunks) > 0 do
                {parsed_chunks, id}
              else
                {[], id}
              end

            %HTTPoison.AsyncEnd{id: ^id} ->
              IO.puts("Stream ended")
              {:halt, nil}

            %HTTPoison.Error{id: ^id, reason: reason} ->
              IO.puts("HTTP error: #{inspect(reason)}")
              {:halt, nil}
          after
            60_000 ->
              IO.puts("Stream timeout")
              {:halt, nil}
          end
      end,
      fn _ ->
        IO.puts("Stream cleanup")
        :ok
      end
    )
  end

  defp maybe_add_functions(body, nil), do: body

  defp maybe_add_functions(body, functions) when is_list(functions) and length(functions) > 0 do
    # Tools are already in correct format
    tools = Enum.map(functions, fn f -> f end)
    Map.put(body, :tools, tools)
  end

  defp maybe_add_functions(body, _functions) do
    body
  end

  defp parse_sse_chunk(chunk) do
    chunk
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(fn line ->
      data = String.replace_prefix(line, "data: ", "")

      case String.trim(data) do
        "[DONE]" ->
          IO.puts("Stream finished with [DONE]")
          %{"choices" => [%{"finish_reason" => "stop"}]}

        "" ->
          nil

        json ->
          case Jason.decode(json) do
            {:ok, parsed_data} ->
              parsed_data

            {:error, _error} ->
              nil
          end
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end
