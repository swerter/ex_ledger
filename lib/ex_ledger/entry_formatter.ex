defmodule ExLedger.EntryFormatter do
  @moduledoc """
  Formats single ledger transaction entries for output.
  """

  alias ExLedger.LedgerParser

  @spec format_entry(map(), Date.t() | nil, boolean()) :: String.t()
  def format_entry(transaction, date \\ nil, include_notes \\ true)

  def format_entry(transaction, nil, include_notes) do
    format_entry(transaction, transaction.date, include_notes)
  end

  def format_entry(transaction, %Date{} = date, include_notes) do
    header = build_transaction_header(transaction, date)
    transaction_notes = if include_notes, do: format_transaction_notes(transaction), else: []

    transaction_metadata = Map.get(transaction, :metadata, %{})

    postings =
      transaction.postings
      |> Enum.with_index()
      |> Enum.flat_map(fn {posting, index} ->
        account = Map.get(posting, :account, "")
        amount_with_assertion = format_posting_amount_with_assertion(posting)
        metadata_to_filter = if include_notes and index == 0, do: transaction_metadata, else: %{}
        notes = if include_notes, do: format_posting_notes(posting, metadata_to_filter), else: []

        posting_line =
          if amount_with_assertion == "" do
            "    #{account}"
          else
            "    #{account}  #{amount_with_assertion}"
          end

        notes ++ [posting_line]
      end)

    Enum.join([header | transaction_notes] ++ postings, "\n") <> "\n"
  end

  defp build_transaction_header(transaction, date) do
    date_string = Calendar.strftime(date, "%Y/%m/%d")
    code = Map.get(transaction, :code, "")
    comment = normalize_comment(Map.get(transaction, :comment))
    payee = Map.get(transaction, :payee, "")
    code_segment = if code == "", do: "", else: " (#{code})"
    comment_segment = if comment, do: "  ; #{comment}", else: ""
    "#{date_string}#{code_segment} #{payee}#{comment_segment}"
  end

  defp format_posting_amount_with_assertion(posting) do
    amount = format_posting_amount(Map.get(posting, :amount))
    assertion = format_posting_amount(Map.get(posting, :assertion))

    case {amount, assertion} do
      {"", ""} -> ""
      {"", assertion_str} -> "0 = #{assertion_str}"
      {amount_str, ""} -> amount_str
      {amount_str, assertion_str} -> "#{amount_str} = #{assertion_str}"
    end
  end

  defp format_posting_amount(nil), do: ""
  defp format_posting_amount(""), do: ""

  defp format_posting_amount(%{value: value, currency: currency} = amount) do
    currency_position = Map.get(amount, :currency_position)
    LedgerParser.format_amount_for_currency(value, currency, currency_position)
  end

  defp format_posting_amount(amount) when is_binary(amount) do
    amount = String.trim(amount)

    case LedgerParser.parse_amount(amount) do
      {:ok, %{value: value, currency: currency} = parsed_amount} ->
        currency_position = Map.get(parsed_amount, :currency_position)
        LedgerParser.format_amount_for_currency(value, currency, currency_position)

      {:error, _} ->
        amount
    end
  end

  defp format_posting_amount(_), do: ""

  defp normalize_comment(nil), do: nil

  defp normalize_comment(comment) when is_binary(comment) do
    if String.trim(comment) == "", do: nil, else: comment
  end

  defp normalize_comment(comment), do: comment

  defp format_posting_notes(posting, transaction_metadata) do
    metadata =
      posting
      |> Map.get(:metadata, %{})
      |> drop_transaction_metadata(transaction_metadata)

    tags = Map.get(posting, :tags, [])
    comments = Map.get(posting, :comments, [])

    metadata_lines =
      metadata
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.flat_map(fn
        {key, values} when is_list(values) ->
          Enum.map(values, fn value -> "    ; #{key}: #{value}" end)

        {key, value} ->
          ["    ; #{key}: #{value}"]
      end)

    tag_lines = Enum.map(tags, &"    ; :#{&1}:")
    comment_lines = Enum.map(comments, &"    ; #{&1}")

    metadata_lines ++ tag_lines ++ comment_lines
  end

  defp drop_transaction_metadata(metadata, transaction_metadata) do
    Enum.reduce(metadata, %{}, fn {key, value}, acc ->
      case Map.get(transaction_metadata, key) do
        nil ->
          Map.put(acc, key, value)

        transaction_value ->
          case remove_duplicate_metadata(value, transaction_value) do
            [] -> acc
            nil -> acc
            remaining -> Map.put(acc, key, remaining)
          end
      end
    end)
  end

  defp remove_duplicate_metadata(values, transaction_values)
       when is_list(values) and is_list(transaction_values) do
    values -- transaction_values
  end

  defp remove_duplicate_metadata(values, transaction_value) when is_list(values) do
    Enum.reject(values, &(&1 == transaction_value))
  end

  defp remove_duplicate_metadata(value, transaction_values) when is_list(transaction_values) do
    if value in transaction_values, do: nil, else: value
  end

  defp remove_duplicate_metadata(value, transaction_value) do
    if value == transaction_value, do: nil, else: value
  end

  defp format_transaction_notes(transaction) do
    metadata = Map.get(transaction, :metadata, %{})

    metadata
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.flat_map(fn
      {key, values} when is_list(values) ->
        Enum.map(values, fn value -> "    ; #{key}: #{value}" end)

      {key, value} ->
        ["    ; #{key}: #{value}"]
    end)
  end
end
