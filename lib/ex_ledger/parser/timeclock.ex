defmodule ExLedger.Parser.Timeclock do
  @moduledoc """
  Parses and reports on timeclock entries.

  Timeclock entries use the format:
    i YYYY/MM/DD HH:MM:SS ACCOUNT  [PAYEE]   ; check-in
    o YYYY/MM/DD HH:MM:SS                    ; check-out (lowercase)
    O YYYY/MM/DD HH:MM:SS                    ; check-out cleared (uppercase)
  """

  @type time_entry :: %{
          account: String.t(),
          start: NaiveDateTime.t(),
          stop: NaiveDateTime.t(),
          payee: String.t() | nil,
          cleared: boolean(),
          duration_seconds: non_neg_integer()
        }

  @doc """
  Parses timeclock entries from input text.

  Returns a list of completed time entries (check-in paired with check-out).
  Warns to stderr about any unclosed check-ins.
  """
  @spec parse_timeclock_entries(String.t()) :: [time_entry()]
  def parse_timeclock_entries(input) when is_binary(input) do
    {entries, open} =
      input
      |> String.split("\n")
      |> Enum.reduce({[], []}, fn line, {entries, open} ->
        line
        |> String.trim()
        |> process_timeclock_line(entries, open)
      end)

    warn_unclosed_timeclock_entries(open)

    entries
  end

  @doc """
  Aggregates timeclock entries by account and returns total hours.
  """
  @spec timeclock_report([time_entry()]) :: %{String.t() => float()}
  def timeclock_report(entries) do
    entries
    |> Enum.group_by(& &1.account)
    |> Enum.map(fn {account, account_entries} ->
      total_seconds =
        Enum.reduce(account_entries, 0, fn entry, acc -> acc + entry.duration_seconds end)

      hours = total_seconds / 3600
      {account, hours}
    end)
    |> Map.new()
  end

  @doc """
  Formats a timeclock report as a string.
  """
  @spec format_timeclock_report(%{String.t() => float()}) :: String.t()
  def format_timeclock_report(report) do
    report
    |> Enum.sort_by(fn {account, _hours} -> account end)
    |> Enum.map_join("\n", fn {account, hours} ->
      formatted_hours = :erlang.float_to_binary(hours, decimals: 2)
      String.pad_leading(formatted_hours, 8) <> "  " <> account
    end)
    |> Kernel.<>("\n")
  end

  # Private functions

  defp process_timeclock_line(trimmed, entries, open) do
    cond do
      String.starts_with?(trimmed, "i ") ->
        handle_timeclock_checkin(trimmed, entries, open)

      String.starts_with?(trimmed, "o ") or String.starts_with?(trimmed, "O ") ->
        handle_timeclock_checkout(trimmed, entries, open)

      true ->
        {entries, open}
    end
  end

  defp handle_timeclock_checkin(trimmed, entries, open) do
    case parse_timeclock_checkin(trimmed) do
      {:ok, entry} -> {entries, [entry | open]}
      _ -> {entries, open}
    end
  end

  defp handle_timeclock_checkout(trimmed, entries, open) do
    {new_entries, remaining} = close_timeclock_entries(trimmed, open)
    {entries ++ new_entries, remaining}
  end

  defp warn_unclosed_timeclock_entries(open) do
    if Enum.empty?(open) do
      :ok
    else
      IO.puts(:stderr, "Warning: #{Enum.count(open)} unclosed timeclock check-in(s)")

      Enum.each(open, fn entry ->
        IO.puts(
          :stderr,
          "  - #{entry.account} checked in at #{NaiveDateTime.to_string(entry.start)}"
        )
      end)
    end
  end

  defp parse_timeclock_checkin(line) do
    case Regex.run(~r/^i\s+(\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2})\s+(\d{2}:\d{2}:\d{2})\s+(.+)$/, line) do
      [_, date_string, time_string, rest] ->
        with {:ok, date} <- parse_date_string(date_string),
             {:ok, time} <- parse_timeclock_time(time_string) do
          {account, payee} = split_account_payee(rest)

          {:ok,
           %{
             account: account,
             start: NaiveDateTime.new!(date, time),
             payee: payee
           }}
        else
          _ -> {:error, :invalid_checkin}
        end

      _ ->
        {:error, :invalid_checkin}
    end
  end

  defp close_timeclock_entries(line, open_entries) do
    case Regex.run(~r/^(o|O)\s+(\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2})\s+(\d{2}:\d{2}:\d{2})$/, line) do
      [_, marker, date_string, time_string] ->
        with {:ok, date} <- parse_date_string(date_string),
             {:ok, time} <- parse_timeclock_time(time_string) do
          stop = NaiveDateTime.new!(date, time)
          cleared = marker == "O"

          entries =
            Enum.map(open_entries, fn entry ->
              duration = max(NaiveDateTime.diff(stop, entry.start, :second), 0)

              %{
                account: entry.account,
                start: entry.start,
                stop: stop,
                payee: entry.payee,
                cleared: cleared,
                duration_seconds: duration
              }
            end)

          {entries, []}
        else
          _ -> {[], open_entries}
        end

      _ ->
        {[], open_entries}
    end
  end

  defp parse_timeclock_time(time_string) do
    case Time.from_iso8601(time_string) do
      {:ok, time} -> {:ok, time}
      _ -> {:error, :invalid_time}
    end
  end

  defp parse_date_string(date_string) do
    case String.split(date_string, ~r/[\/\-]/) do
      [year, month, day] ->
        with {year, ""} <- Integer.parse(year),
             {month, ""} <- Integer.parse(month),
             {day, ""} <- Integer.parse(day),
             {:ok, date} <- Date.new(year, month, day) do
          {:ok, date}
        else
          _ -> {:error, :invalid_date}
        end

      _ ->
        {:error, :invalid_date}
    end
  end

  defp split_account_payee(rest) do
    case String.split(rest, ~r/\s{2,}/, parts: 2) do
      [account] -> {String.trim(account), nil}
      [account, payee] -> {String.trim(account), String.trim(payee)}
    end
  end
end
