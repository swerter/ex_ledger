defmodule ExLedger.EntryFormatter do
  @moduledoc """
  Formats single ledger transaction entries for output.
  """

  alias ExLedger.LedgerParser

  @spec format_entry(map(), Date.t() | nil) :: String.t()
  def format_entry(transaction, date \\ nil)

  def format_entry(transaction, nil) do
    format_entry(transaction, transaction.date)
  end

  def format_entry(transaction, %Date{} = date) do
    header = build_transaction_header(transaction, date)

    postings =
      Enum.map(transaction.postings, fn posting ->
        amount = format_posting_amount(posting.amount)

        if amount == "" do
          "    #{posting.account}"
        else
          "    #{posting.account}  #{amount}"
        end
      end)

    Enum.join([header | postings], "\n") <> "\n"
  end

  defp build_transaction_header(transaction, date) do
    date_string = Calendar.strftime(date, "%Y/%m/%d")
    code_segment = if transaction.code == "", do: "", else: " (#{transaction.code})"
    comment_segment = if transaction.comment, do: "  ; #{transaction.comment}", else: ""
    "#{date_string}#{code_segment} #{transaction.payee}#{comment_segment}"
  end

  defp format_posting_amount(nil), do: ""

  defp format_posting_amount(%{value: value, currency: currency}) do
    LedgerParser.format_amount_for_currency(value, currency)
  end
end
