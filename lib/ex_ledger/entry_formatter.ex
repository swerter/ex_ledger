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

    postings =
      Enum.flat_map(transaction.postings, fn posting ->
        account = Map.get(posting, :account) || Map.get(posting, "account") || ""
        amount = format_posting_amount(Map.get(posting, :amount) || Map.get(posting, "amount"))
        notes = if include_notes, do: format_posting_notes(posting), else: []

        posting_line =
          if amount == "" do
            "    #{account}"
          else
            "    #{account}  #{amount}"
          end

        notes ++ [posting_line]
      end)

    Enum.join([header | postings], "\n") <> "\n"
  end

  defp build_transaction_header(transaction, date) do
    date_string = Calendar.strftime(date, "%Y/%m/%d")
    code = Map.get(transaction, :code) || Map.get(transaction, "code") || ""
    comment = normalize_comment(Map.get(transaction, :comment) || Map.get(transaction, "comment"))
    payee = Map.get(transaction, :payee) || Map.get(transaction, "payee") || ""
    code_segment = if code == "", do: "", else: " (#{code})"
    comment_segment = if comment, do: "  ; #{comment}", else: ""
    "#{date_string}#{code_segment} #{payee}#{comment_segment}"
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

  defp format_posting_notes(posting) do
    metadata = Map.get(posting, :metadata) || Map.get(posting, "metadata") || %{}
    tags = Map.get(posting, :tags) || Map.get(posting, "tags") || []
    comments = Map.get(posting, :comments) || Map.get(posting, "comments") || []

    metadata_lines =
      metadata
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, value} -> "    ; #{key}: #{value}" end)

    tag_lines = Enum.map(tags, &"    ; :#{&1}:")
    comment_lines = Enum.map(comments, &"    ; #{&1}")

    metadata_lines ++ tag_lines ++ comment_lines
  end
end
