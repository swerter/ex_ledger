defmodule ExLedger.LedgerCLITest do
  use ExUnit.Case
  import ExUnit.CaptureIO
  alias ExLedger.TestHelpers

  @fixtures_dir Path.expand("fixtures", __DIR__)
  @ledger_file Path.join(@fixtures_dir, "ledger_cli.ledger")
  @list_commands ~w(accounts payees commodities tags)

  setup do
    case TestHelpers.require_executable("ledger") do
      {:ok, ledger_bin} -> {:ok, ledger_bin: ledger_bin}
      {:skip, reason} -> {:skip, reason}
    end
  end

  for command <- @list_commands do
    test "#{command} matches ledger-cli output", %{ledger_bin: ledger_bin} do
      command = unquote(command)

      ledger_output = ledger_cli_output(ledger_bin, command)
      elixir_output = elixir_cli_output(command)

      assert normalize_list_output(elixir_output) == normalize_list_output(ledger_output)
    end
  end

  test "balance matches ledger-cli output", %{ledger_bin: ledger_bin} do
    ledger_output = ledger_cli_output(ledger_bin, "balance")
    elixir_output = elixir_cli_output("balance")

    assert balance_entries(elixir_output) == balance_entries(ledger_output)
  end

  test "stats matches ledger-cli output", %{ledger_bin: ledger_bin} do
    ledger_output = ledger_cli_output(ledger_bin, "stats")
    elixir_output = elixir_cli_output("stats")

    assert parse_stats_output(elixir_output) == parse_stats_output(ledger_output)
  end

  test "select matches ledger-cli output", %{ledger_bin: ledger_bin} do
    query = "payee from posts"

    ledger_output = ledger_cli_output(ledger_bin, "select", [query])
    elixir_output = elixir_cli_output("select", [query])

    assert normalize_select_output(elixir_output) == normalize_select_output(ledger_output)
  end

  test "xact matches ledger-cli output", %{ledger_bin: ledger_bin} do
    args = ["2024/01/03", "Grocery"]

    ledger_output = ledger_cli_output(ledger_bin, "xact", args)
    elixir_output = elixir_cli_output("xact", args)

    assert normalize_xact_output(elixir_output) == normalize_xact_output(ledger_output)
  end

  defp elixir_cli_output(command, args \\ []) do
    capture_io(fn ->
      ExLedger.CLI.main(["-f", @ledger_file, command | args])
    end)
  end

  defp ledger_cli_output(ledger_bin, command, args \\ []) do
    case ExLedger.LedgerCLI.run_with_file(@ledger_file, command, args, ledger_bin: ledger_bin) do
      {:ok, output} ->
        output

      {:error, {status, output}} ->
        flunk("ledger-cli exited with #{status}: #{output}")
    end
  end

  defp normalize_list_output(output) do
    output
    |> normalize_select_output()
    |> Enum.sort()
  end

  defp normalize_select_output(output) do
    normalized_lines(output)
  end

  defp balance_entries(output) do
    output
    |> normalized_lines()
    |> Enum.reduce([], fn line, acc ->
      case parse_balance_entry(line) do
        nil -> acc
        entry -> [entry | acc]
      end
    end)
    |> Enum.sort()
  end

  defp parse_balance_entry(line) do
    if Regex.match?(~r/^[-]+$/, line) do
      nil
    else
      case Regex.run(~r/^(.+?)\s{2,}(\S.+)$/, line) do
        [_, amount, account] ->
          {String.trim(account), String.trim(amount)}

        _ ->
          nil
      end
    end
  end

  defp normalize_xact_output(output) do
    lines = normalized_lines(output)

    {header, posting_lines} =
      case lines do
        [header | rest] -> {header, rest}
        _ -> {"", []}
      end

    accounts =
      posting_lines
      |> Enum.map(&strip_xact_comment/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn line ->
        case Regex.run(~r/^(\S.+?)(?:\s{2,}.*)?$/, line) do
          [_, account] -> String.trim(account)
          _ -> String.trim(line)
        end
      end)

    %{header: header, accounts: accounts}
  end

  defp strip_xact_comment(line) do
    String.replace(line, ~r/\s+;.*$/, "")
  end

  defp normalized_lines(output) do
    output
    |> String.replace("\r\n", "\n")
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_stats_output(output) do
    output
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      acc
      |> maybe_put_stat(:unique_accounts, ~r/Unique accounts:\s+(\d+)/, line)
      |> maybe_put_stat(:unique_payees, ~r/Unique payees:\s+(\d+)/, line)
      |> maybe_put_stat(:postings_total, ~r/(?:Postings total|Number of postings):\s+(\d+)/, line)
      |> maybe_put_stat(
        :days_since_last_posting,
        ~r/Days since last (?:posting|post):\s+(\d+)/,
        line
      )
      |> maybe_put_stat(:posts_last_7_days, ~r/Posts in (?:the )?last 7 days:\s+(\d+)/, line)
      |> maybe_put_stat(:posts_last_30_days, ~r/Posts in (?:the )?last 30 days:\s+(\d+)/, line)
      |> maybe_put_stat(:posts_this_month, ~r/Posts (?:this|seen this) month:\s+(\d+)/, line)
    end)
  end

  defp maybe_put_stat(acc, key, regex, line) do
    case Regex.run(regex, line) do
      [_, value] -> Map.put(acc, key, String.to_integer(value))
      _ -> acc
    end
  end
end
