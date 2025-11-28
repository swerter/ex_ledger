defmodule ExLedger.CLI do
  @moduledoc false

  @switches [file: :string, help: :boolean]
  @aliases [f: :file, h: :help]

  @doc """
  Entry point for the CLI. Accepts arguments like `-f ledger.dat balance`.
  """
  @spec main([String.t()]) :: :ok
  def main(argv) do
    argv
    |> parse_args()
    |> execute()
  end

  defp parse_args(argv) do
    {opts, commands, _} = OptionParser.parse(argv, switches: @switches, aliases: @aliases)

    %{
      file: opts[:file],
      command: List.first(commands) || "balance",
      help?: opts[:help] || false
    }
  end

  defp execute(%{help?: true}) do
    print_usage()
  end

  defp execute(%{file: nil}) do
    print_error("missing required option `-f/--file`")
    print_usage()
    System.halt(64)
  end

  defp execute(%{file: file, command: "balance"}) do
    file
    |> File.read()
    |> case do
      {:ok, contents} ->
        # Get the directory of the main file for resolving includes
        base_dir = Path.dirname(file)

        case ExLedger.LedgerParser.parse_ledger_with_includes(contents, base_dir) do
          {:ok, transactions} ->
            transactions
            |> ExLedger.LedgerParser.balance()
            |> ExLedger.LedgerParser.format_balance()
            |> IO.write()

          {:error, {reason, line}} ->
            print_error(
              "failed to parse ledger file #{format_error_location(file, line)}: #{format_parse_error(reason)}"
            )
            System.halt(1)

          {:error, reason} ->
            print_error("failed to parse ledger file #{format_error_location(file, nil)}: #{format_parse_error(reason)}")
            System.halt(1)
        end

      {:error, reason} ->
        print_error("cannot read file #{file}: #{:file.format_error(reason)}")
        System.halt(1)
    end
  end

  defp execute(%{command: command}) do
    print_error("unknown command #{command}")
    print_usage()
    System.halt(64)
  end

  defp print_usage do
    [
      "Usage: exledger -f <ledger_file> balance",
      "",
      "Options:",
      "  -f, --file    Path to the ledger file",
      "  -h, --help    Show this message"
    ]
    |> Enum.join("\n")
    |> IO.puts()
  end

  defp print_error(message) do
    IO.puts(:stderr, "exledger: #{message}")
  end

  defp format_error_location(file, nil), do: file
  defp format_error_location(file, line), do: "#{file}:#{line}"

  defp format_parse_error({:unexpected_input, rest}), do: "unexpected input #{inspect(rest)}"
  defp format_parse_error({:include_not_found, filename}), do: "include file not found: #{filename}"
  defp format_parse_error({:circular_include, filename}), do: "circular include detected: #{filename}"
  defp format_parse_error({:file_read_error, filename, reason}), do: "cannot read include file #{filename}: #{:file.format_error(reason)}"
  defp format_parse_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_parse_error(reason), do: inspect(reason)
end
