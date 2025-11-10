defmodule Exterm.Llm.Tools.File do
  @moduledoc """
  File operation tools for AI assistant.
  """

  @doc """
  Create a new file with specified content
  """
  def create_file(%{"path" => path, "content" => content}, _chat_socket_pid) do
    try do
      # Ensure directory exists
      path |> Path.dirname() |> File.mkdir_p!()

      case File.write(path, content) do
        :ok ->
          %{
            "success" => true,
            "message" => "File created successfully at #{path}",
            "path" => path,
            "size" => byte_size(content)
          }

        {:error, reason} ->
          %{
            "success" => false,
            "error" => "Failed to create file: #{reason}"
          }
      end
    rescue
      error ->
        %{
          "success" => false,
          "error" => "Error creating file: #{Exception.message(error)}"
        }
    end
  end

  @doc """
  Read content from a file
  """
  def read_file(%{"path" => path} = params, _chat_socket_pid) do
    try do
      case File.read(path) do
        {:ok, content} ->
          start_line = Map.get(params, "start_line")
          end_line = Map.get(params, "end_line")

          if start_line || end_line do
            lines = String.split(content, "\n")
            total_lines = length(lines)

            start_idx = max(0, (start_line || 1) - 1)
            end_idx = min(total_lines - 1, (end_line || total_lines) - 1)

            selected_lines = Enum.slice(lines, start_idx..end_idx)
            selected_content = Enum.join(selected_lines, "\n")

            %{
              "success" => true,
              "content" => selected_content,
              "path" => path,
              "lines_shown" => "#{start_idx + 1}-#{end_idx + 1}",
              "total_lines" => total_lines
            }
          else
            %{
              "success" => true,
              "content" => content,
              "path" => path,
              "total_lines" => content |> String.split("\n") |> length()
            }
          end

        {:error, reason} ->
          %{
            "success" => false,
            "error" => "Failed to read file: #{reason}"
          }
      end
    rescue
      error ->
        %{
          "success" => false,
          "error" => "Error reading file: #{Exception.message(error)}"
        }
    end
  end

  @doc """
  Update entire file content
  """
  def update_file(%{"path" => path, "content" => content}, _chat_socket_pid) do
    try do
      case File.write(path, content) do
        :ok ->
          %{
            "success" => true,
            "message" => "File updated successfully",
            "path" => path,
            "new_size" => byte_size(content)
          }

        {:error, reason} ->
          %{
            "success" => false,
            "error" => "Failed to update file: #{reason}"
          }
      end
    rescue
      error ->
        %{
          "success" => false,
          "error" => "Error updating file: #{Exception.message(error)}"
        }
    end
  end

  @doc """
  Append content to end of file
  """
  def append_to_file(%{"path" => path, "content" => content}, _chat_socket_pid) do
    try do
      case File.exists?(path) do
        true ->
          case File.read(path) do
            {:ok, existing_content} ->
              new_content = existing_content <> content

              case File.write(path, new_content) do
                :ok ->
                  %{
                    "success" => true,
                    "message" => "Content appended successfully",
                    "path" => path,
                    "appended_bytes" => byte_size(content)
                  }

                {:error, reason} ->
                  %{
                    "success" => false,
                    "error" => "Failed to append to file: #{reason}"
                  }
              end

            {:error, reason} ->
              %{
                "success" => false,
                "error" => "Failed to read existing file: #{reason}"
              }
          end

        false ->
          case File.write(path, content) do
            :ok ->
              %{
                "success" => true,
                "message" => "File created with appended content",
                "path" => path,
                "size" => byte_size(content)
              }

            {:error, reason} ->
              %{
                "success" => false,
                "error" => "Failed to create file: #{reason}"
              }
          end
      end
    rescue
      error ->
        %{
          "success" => false,
          "error" => "Error appending to file: #{Exception.message(error)}"
        }
    end
  end

  @doc """
  Delete a file
  """
  def delete_file(%{"path" => path}, _chat_socket_pid) do
    try do
      case File.rm(path) do
        :ok ->
          %{
            "success" => true,
            "message" => "File deleted successfully",
            "path" => path
          }

        {:error, reason} ->
          %{
            "success" => false,
            "error" => "Failed to delete file: #{reason}"
          }
      end
    rescue
      error ->
        %{
          "success" => false,
          "error" => "Error deleting file: #{Exception.message(error)}"
        }
    end
  end

  @doc """
  Edit specific lines in a file
  """
  def edit_lines(%{
    "path" => path,
    "start_line" => start_line,
    "end_line" => end_line,
    "new_content" => new_content
  }, _chat_socket_pid) do
    try do
      case File.read(path) do
        {:ok, content} ->
          lines = String.split(content, "\n")
          total_lines = length(lines)

          if start_line < 1 || end_line < start_line || start_line > total_lines do
            %{
              "success" => false,
              "error" => "Invalid line numbers. File has #{total_lines} lines. Start: #{start_line}, End: #{end_line}"
            }
          else
            start_idx = start_line - 1
            end_idx = min(end_line - 1, total_lines - 1)

            new_lines = String.split(new_content, "\n")

            before_lines = Enum.slice(lines, 0, start_idx)
            after_lines = Enum.slice(lines, end_idx + 1, total_lines)

            new_file_lines = before_lines ++ new_lines ++ after_lines
            new_file_content = Enum.join(new_file_lines, "\n")

            case File.write(path, new_file_content) do
              :ok ->
                %{
                  "success" => true,
                  "message" => "Lines #{start_line}-#{end_line} edited successfully",
                  "path" => path,
                  "lines_affected" => end_line - start_line + 1,
                  "new_total_lines" => length(new_file_lines)
                }

              {:error, reason} ->
                %{
                  "success" => false,
                  "error" => "Failed to write file: #{reason}"
                }
            end
          end

        {:error, reason} ->
          %{
            "success" => false,
            "error" => "Failed to read file: #{reason}"
          }
      end
    rescue
      error ->
        %{
          "success" => false,
          "error" => "Error editing lines: #{Exception.message(error)}"
        }
    end
  end

    @doc """
  Find and replace text in a file using literal string matching
  """
  def find_and_replace_in_file(%{"path" => path, "search_text" => search_text, "replace_text" => replace_text} = params, _chat_socket_pid) do
    max_replacements = Map.get(params, "max_replacements", :all)
    
    case file_exists?(path) do
      false ->
        %{
          "success" => false,
          "error" => "File not found: #{path}"
        }
        
      true ->
        try do
          content = File.read!(path)
          
          {new_content, replacement_count} = if max_replacements == :all do
            new_content = String.replace(content, search_text, replace_text, global: true)
            {new_content, count_occurrences(content, search_text)}
          else
            replace_limited(content, search_text, replace_text, max_replacements, 0)
          end
          
          if replacement_count > 0 do
            case File.write(path, new_content) do
              :ok ->
                %{
                  "success" => true,
                  "message" => "Successfully replaced #{replacement_count} occurrence(s) in #{path}",
                  "replacements_made" => replacement_count
                }
                
              {:error, reason} ->
                %{
                  "success" => false,
                  "error" => "Failed to write file: #{reason}"
                }
            end
          else
            %{
              "success" => true,
              "message" => "No occurrences of '#{search_text}' found in #{path}",
              "replacements_made" => 0
            }
          end
        rescue
          error ->
            %{
              "success" => false,
              "error" => "Error processing file: #{Exception.message(error)}"
            }
        end
    end
  end

  @doc """
  List files and directories in a specified path
  """
  def list_files(params, _chat_socket_pid) do
    path = Map.get(params, "path", ".")

    try do
      case File.ls(path) do
        {:ok, files} ->
          file_info =
            Enum.map(files, fn file ->
              full_path = Path.join(path, file)
              stat = File.stat!(full_path)

              modified_time =
                case stat.mtime do
                  %DateTime{} = dt ->
                    DateTime.to_string(dt)

                  unix_time when is_integer(unix_time) ->
                    DateTime.from_unix!(unix_time) |> DateTime.to_string()

                  {{year, month, day}, {hour, minute, second}} ->
                    {:ok, dt} =
                      DateTime.new(Date.new!(year, month, day), Time.new!(hour, minute, second))

                    DateTime.to_string(dt)

                  _ ->
                    "unknown"
                end

              %{
                "name" => file,
                "type" => if(stat.type == :directory, do: "directory", else: "file"),
                "size" => stat.size,
                "modified" => modified_time
              }
            end)
            |> Enum.sort_by(fn item -> {item["type"], item["name"]} end)

          %{
            "success" => true,
            "path" => path,
            "files" => file_info,
            "count" => length(file_info)
          }

        {:error, reason} ->
          %{
            "success" => false,
            "error" => "Failed to list directory: #{reason}"
          }
      end
    rescue
      error ->
        %{
          "success" => false,
          "error" => "Error listing files: #{Exception.message(error)}"
        }
    end
  end

  # Private helper functions
  
  defp file_exists?(path) do
    File.exists?(path)
  end
  
  defp count_occurrences(string, substring) do
    string
    |> String.split(substring)
    |> length()
    |> Kernel.-(1)
    |> max(0)
  end
  
  defp replace_limited(content, _search_text, _replace_text, 0, count), do: {content, count}
  defp replace_limited(content, search_text, replace_text, max_remaining, count) do
    case String.split(content, search_text, parts: 2) do
      [_] -> {content, count}  # No more occurrences
      [before, after_part] ->
        new_content = before <> replace_text <> after_part
        replace_limited(new_content, search_text, replace_text, max_remaining - 1, count + 1)
    end
  end
end
