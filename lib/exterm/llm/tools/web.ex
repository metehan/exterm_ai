defmodule Exterm.Llm.Tools.Web do
  @moduledoc """
  Web browsing and searching tools for AI assistant.
  """

  @doc """
  Browse a web page and extract readable content
  """
  def browse_web(%{"url" => url} = params, _chat_socket_pid) do
    max_length = Map.get(params, "max_content_length", 8000) |> min(20000)

    try do
      formatted_url = if String.starts_with?(url, "http"), do: url, else: "https://#{url}"

      unless valid_url?(formatted_url) do
        %{
          "success" => false,
          "error" =>
            "Invalid URL format. Consider using search_web first to find the correct URL.",
          "suggestion" =>
            "Try using search_web tool instead to find the website you're looking for."
        }
      else
        ssl_options = [verify: :verify_none]

        case HTTPoison.get(formatted_url, [{"User-Agent", "Exterm AI Browser 1.0"}],
               timeout: 15000,
               recv_timeout: 15000,
               ssl: ssl_options,
               hackney: [decompress_body: true]
             ) do
          {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
            {content, metadata} = extract_readable_content(body, formatted_url)

            final_content =
              if String.length(content) > max_length do
                String.slice(content, 0, max_length) <>
                  "\n\n... [Content truncated. Use max_content_length parameter for longer content]"
              else
                content
              end

            response = %{
              "success" => true,
              "url" => formatted_url,
              "content" => final_content,
              "content_length" => String.length(final_content),
              "truncated" => String.length(content) > max_length
            }

            response =
              if metadata.title && String.trim(metadata.title) != "" do
                Map.put(response, "title", metadata.title)
              else
                response
              end

            response =
              if metadata.authors && length(metadata.authors) > 0 do
                Map.put(response, "authors", metadata.authors)
              else
                response
              end

            response

          {:ok, %HTTPoison.Response{status_code: 404}} ->
            %{
              "success" => false,
              "error" => "Page not found (404). The URL may not exist.",
              "suggestion" =>
                "Try using search_web to find the correct URL for the content you're looking for."
            }

          {:ok, %HTTPoison.Response{status_code: status_code}} ->
            %{
              "success" => false,
              "error" => "HTTP #{status_code}: Failed to fetch page",
              "suggestion" =>
                "The website may be down or the URL may be incorrect. Try search_web to find alternative sources."
            }

          {:error, %HTTPoison.Error{reason: :nxdomain}} ->
            %{
              "success" => false,
              "error" => "Domain not found. The website does not exist.",
              "suggestion" =>
                "Use search_web to find the correct website or check for typos in the domain name."
            }

          {:error, %HTTPoison.Error{reason: reason}} ->
            %{
              "success" => false,
              "error" => "Network error: #{reason}",
              "suggestion" =>
                "The website may be down or unreachable. Try search_web to find alternative sources."
            }
        end
      end
    rescue
      error ->
        %{
          "success" => false,
          "error" => "Error browsing web: #{Exception.message(error)}",
          "suggestion" => "Consider using search_web first to find valid URLs."
        }
    end
  end

  @doc """
  Search the web using DuckDuckGo
  """
  def search_web(%{"query" => query} = params, _chat_socket_pid) do
    max_results = Map.get(params, "max_results", 5) |> min(10)

    try do
      search_url = "https://lite.duckduckgo.com/lite/?q=#{URI.encode(query)}"

      headers = [
        {"User-Agent", "Mozilla/5.0 (X11; Linux x86_64; rv:91.0) Gecko/20100101 Firefox/91.0"},
        {"Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8"},
        {"Accept-Language", "en-US,en;q=0.5"},
        {"DNT", "1"},
        {"Connection", "keep-alive"},
        {"Upgrade-Insecure-Requests", "1"}
      ]

      options = [timeout: 15000, recv_timeout: 15000, hackney: [decompress_body: true]]

      case HTTPoison.get(search_url, headers, options) do
        {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
          results = parse_duckduckgo_lite_results(body, max_results)

          if Enum.empty?(results) do
            %{
              "success" => false,
              "error" => "No search results found for '#{query}'. Try different keywords."
            }
          else
            formatted_results = format_search_results(results, query)

            %{
              "success" => true,
              "query" => query,
              "results_count" => length(results),
              "results" => formatted_results
            }
          end

        {:ok, %HTTPoison.Response{status_code: status_code}} ->
          %{
            "success" => false,
            "error" => "Search failed with HTTP #{status_code}. Try again later."
          }

        {:error, %HTTPoison.Error{reason: reason}} ->
          %{
            "success" => false,
            "error" => "Network error: #{reason}. Check internet connection."
          }
      end
    rescue
      error ->
        %{
          "success" => false,
          "error" => "Error searching web: #{Exception.message(error)}"
        }
    end
  end

  # Private helper functions

  defp valid_url?(url) do
    uri = URI.parse(url)

    uri.scheme in ["http", "https"] and
      not is_nil(uri.host) and
      String.length(uri.host) > 2 and
      String.contains?(uri.host, ".")
  end

  defp extract_readable_content(html, _url) do
    try do
      {:ok, document} = Floki.parse_document(html)

      title = extract_page_title(document)
      main_content = find_main_content(document)

      content =
        main_content
        |> convert_elements_to_markdown()
        |> clean_extracted_content()

      metadata = %{
        title: title,
        authors: []
      }

      {content, metadata}
    rescue
      error ->
        IO.puts("Content extraction failed: #{Exception.message(error)}")
        {html_to_markdown(html), %{title: nil, authors: []}}
    end
  end

  defp extract_page_title(document) do
    title_sources = [
      "title",
      "h1",
      "[property='og:title']",
      "[name='twitter:title']",
      ".article-title",
      ".headline"
    ]

    Enum.find_value(title_sources, fn selector ->
      case Floki.find(document, selector) do
        [element | _] ->
          text = Floki.text(element) |> String.trim()
          if String.length(text) > 0, do: text, else: nil

        _ ->
          nil
      end
    end)
  end

  defp find_main_content(document) do
    content_selectors = [
      "article",
      "main",
      "[role='main']",
      ".article-content",
      ".post-content",
      ".content",
      ".entry-content",
      "#content",
      ".main-content"
    ]

    Enum.find_value(content_selectors, fn selector ->
      case Floki.find(document, selector) do
        [element | _] ->
          text_length = Floki.text(element) |> String.length()
          if text_length > 200, do: element, else: nil

        _ ->
          nil
      end
    end) ||
      document
      |> Floki.find("body")
      |> List.first()
      |> filter_noise_elements()
  end

  defp filter_noise_elements(nil), do: []

  defp filter_noise_elements(element) do
    noise_selectors = [
      "nav",
      "header",
      "footer",
      "aside",
      ".navigation",
      ".nav",
      ".menu",
      ".advertisement",
      ".ads",
      ".ad",
      ".social",
      ".share",
      ".comments",
      ".sidebar",
      ".widget",
      ".related"
    ]

    Enum.reduce(noise_selectors, element, fn selector, acc ->
      Floki.filter_out(acc, selector)
    end)
  end

  defp clean_extracted_content(content) do
    content
    |> String.replace(~r/\s+/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
    |> add_extraction_note()
  end

  defp add_extraction_note(content) do
    if String.length(content) > 100 do
      "**[Content extracted using reader-mode algorithm]**\n\n" <> content
    else
      content
    end
  end

  defp convert_elements_to_markdown(elements) when is_list(elements) do
    elements
    |> Enum.map(&convert_element_to_markdown/1)
    |> Enum.join("")
  end

  defp convert_elements_to_markdown(element) when is_tuple(element) do
    convert_element_to_markdown(element)
  end

  defp convert_elements_to_markdown(nil), do: ""

  defp convert_element_to_markdown({tag, attrs, children}) do
    case tag do
      "h1" ->
        "# #{extract_text(children)}\n\n"

      "h2" ->
        "## #{extract_text(children)}\n\n"

      "h3" ->
        "### #{extract_text(children)}\n\n"

      "h4" ->
        "#### #{extract_text(children)}\n\n"

      "h5" ->
        "##### #{extract_text(children)}\n\n"

      "h6" ->
        "###### #{extract_text(children)}\n\n"

      "p" ->
        "#{convert_elements_to_markdown(children)}\n\n"

      "br" ->
        "\n"

      "a" ->
        href = get_attribute(attrs, "href")
        text = extract_text(children)

        if href && String.trim(text) != "" do
          "[#{text}](#{href})"
        else
          text
        end

      "strong" ->
        "**#{extract_text(children)}**"

      "b" ->
        "**#{extract_text(children)}**"

      "em" ->
        "*#{extract_text(children)}*"

      "i" ->
        "*#{extract_text(children)}*"

      "code" ->
        "`#{extract_text(children)}`"

      "pre" ->
        "```\n#{extract_text(children)}\n```\n\n"

      "ul" ->
        list_items = convert_list_items(children, "-")
        "#{list_items}\n"

      "ol" ->
        list_items = convert_list_items(children, "1.")
        "#{list_items}\n"

      "li" ->
        "#{convert_elements_to_markdown(children)}"

      "div" ->
        "#{convert_elements_to_markdown(children)}"

      "section" ->
        "#{convert_elements_to_markdown(children)}"

      "article" ->
        "#{convert_elements_to_markdown(children)}"

      "main" ->
        "#{convert_elements_to_markdown(children)}"

      "span" ->
        "#{convert_elements_to_markdown(children)}"

      "table" ->
        "\n#{convert_table_to_markdown(children)}\n"

      "blockquote" ->
        "> #{extract_text(children)}\n\n"

      _ ->
        "#{convert_elements_to_markdown(children)}"
    end
  end

  defp convert_element_to_markdown(text) when is_binary(text) do
    text |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  defp convert_element_to_markdown(nil), do: ""
  defp convert_element_to_markdown(_), do: ""

  defp extract_text(elements) when is_list(elements) do
    elements
    |> Enum.map(&extract_text/1)
    |> Enum.join("")
    |> String.trim()
  end

  defp extract_text({_tag, _attrs, children}) do
    extract_text(children)
  end

  defp extract_text(text) when is_binary(text) do
    text |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  defp extract_text(nil), do: ""
  defp extract_text(_), do: ""

  defp get_attribute(attrs, name) do
    case Enum.find(attrs, fn {attr_name, _} -> attr_name == name end) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp convert_list_items(children, marker) do
    children
    |> Enum.filter(fn
      {"li", _, _} -> true
      _ -> false
    end)
    |> Enum.map(fn {"li", _, li_children} ->
      "#{marker} #{extract_text(li_children)}"
    end)
    |> Enum.join("\n")
  end

  defp convert_table_to_markdown(children) do
    rows = Floki.find(children, "tr")

    case rows do
      [] ->
        ""

      _ ->
        rows
        |> Enum.map(fn {_, _, cells} ->
          cell_text =
            cells
            |> Enum.filter(fn
              {"td", _, _} -> true
              {"th", _, _} -> true
              _ -> false
            end)
            |> Enum.map(fn {_, _, cell_children} -> extract_text(cell_children) end)
            |> Enum.join(" | ")

          "| #{cell_text} |"
        end)
        |> Enum.join("\n")
    end
  end

  defp html_to_markdown(html) do
    try do
      {:ok, document} = Floki.parse_document(html)

      cleaned_document =
        document
        |> Floki.filter_out("script")
        |> Floki.filter_out("style")
        |> Floki.filter_out("noscript")
        |> Floki.filter_out("nav")
        |> Floki.filter_out(".advertisement")
        |> Floki.filter_out(".ads")
        |> Floki.filter_out(".sidebar")
        |> Floki.filter_out("footer")
        |> Floki.filter_out("#footer")

      cleaned_document
      |> convert_elements_to_markdown()
      |> String.trim()
    rescue
      _error ->
        html
        |> String.replace(~r/<script[^>]*>.*?<\/script>/si, "")
        |> String.replace(~r/<style[^>]*>.*?<\/style>/si, "")
        |> Floki.text()
    end
  end

  defp parse_duckduckgo_lite_results(html, max_results) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        tables = Floki.find(document, "table")

        result_table =
          Enum.find(tables, fn table ->
            links = Floki.find(table, "a.result-link")
            length(links) > 0
          end)

        case result_table do
          nil ->
            []

          table ->
            result_links = Floki.find(table, "a.result-link")

            result_links
            |> Enum.take(max_results)
            |> Enum.map(fn link ->
              title = Floki.text(link) |> String.trim()
              href = Floki.attribute(link, "href") |> List.first() || ""

              parent_row = find_parent_element(table, link, "tr")

              snippet =
                case parent_row do
                  nil ->
                    ""

                  row ->
                    all_rows = Floki.find(table, "tr")
                    row_index = Enum.find_index(all_rows, fn r -> r == row end)

                    if row_index do
                      all_rows
                      |> Enum.drop(row_index + 1)
                      |> Enum.take(3)
                      |> Enum.find_value("", fn next_row ->
                        snippet_element = Floki.find(next_row, ".result-snippet")

                        if length(snippet_element) > 0 do
                          Floki.text(snippet_element) |> String.trim()
                        else
                          nil
                        end
                      end)
                    else
                      ""
                    end
                end

              %{
                title: title,
                url: href,
                snippet: snippet |> String.slice(0, 200)
              }
            end)
            |> Enum.filter(fn result ->
              valid_search_result?(result.url, result.title)
            end)
        end

      {:error, _reason} ->
        []
    end
  end

  defp find_parent_element(root, target_element, parent_tag) do
    Floki.find(root, parent_tag)
    |> Enum.find(fn row ->
      row_links = Floki.find(row, "a.result-link")

      Enum.any?(row_links, fn link ->
        Floki.text(link) == Floki.text(target_element) and
          Floki.attribute(link, "href") == Floki.attribute(target_element, "href")
      end)
    end)
  end

  defp format_search_results(results, query) do
    header = "# Search Results for: #{query}\n\n"

    if Enum.empty?(results) do
      header <> "No results found. Try different search terms or check spelling."
    else
      results_text =
        results
        |> Enum.with_index(1)
        |> Enum.map(fn {result, index} ->
          snippet_text =
            if String.trim(result.snippet) != "" do
              "\n   *#{result.snippet}*"
            else
              ""
            end

          "#{index}. **[#{result.title}](#{result.url})**#{snippet_text}"
        end)
        |> Enum.join("\n\n")

      footer =
        "\n\n*Use browse_web with any of the above URLs to read the full content. For example: browse_web(url: \"#{List.first(results).url}\")*"

      header <> results_text <> footer
    end
  end

  defp valid_search_result?(url, title) do
    not String.contains?(url, ["javascript:", "mailto:", "#"]) and
      String.length(String.trim(title)) > 3 and
      String.contains?(url, [".com", ".org", ".net", ".edu", ".gov", ".io", ".co"])
  end
end
