defmodule ExLedger.Predicate.Evaluator do
  @moduledoc """
  Evaluates predicate ASTs against transaction/posting contexts.

  Takes an AST produced by `ExLedger.Predicate.Parser` and evaluates it
  against a context containing transaction and posting data.

  ## Example

      iex> ast = {:account_regex, ~r/^Expenses:/}
      iex> ctx = Evaluator.context(transaction, posting)
      iex> Evaluator.matches?(ast, ctx)
      true
  """

  alias ExLedger.Predicate.Parser

  defmodule Context do
    @moduledoc """
    Evaluation context containing transaction and posting data.
    """

    @type t :: %__MODULE__{
            transaction: map(),
            posting: map(),
            posting_index: non_neg_integer()
          }

    defstruct [
      :transaction,
      :posting,
      :posting_index
    ]
  end

  @type ast :: Parser.ast()

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Creates an evaluation context from a transaction and posting.

  ## Options

  - `:posting_index` - Index of the posting in the transaction (default: 0)
  """
  @spec context(map(), map(), keyword()) :: Context.t()
  def context(transaction, posting, opts \\ []) do
    %Context{
      transaction: transaction,
      posting: posting,
      posting_index: Keyword.get(opts, :posting_index, 0)
    }
  end

  @doc """
  Evaluates a predicate AST against an evaluation context.

  Returns `true` if the predicate matches, `false` otherwise.
  """
  @spec matches?(ast(), Context.t()) :: boolean()

  # Account regex - matches against posting account
  def matches?({:account_regex, regex}, %Context{posting: posting}) do
    account = get_in(posting, [:account]) || Map.get(posting, "account")
    account != nil and Regex.match?(regex, account)
  end

  # Payee regex - matches against transaction payee
  def matches?({:payee_regex, regex}, %Context{transaction: transaction}) do
    payee = get_in(transaction, [:payee]) || Map.get(transaction, "payee")
    payee != nil and Regex.match?(regex, payee)
  end

  # Note regex - matches against transaction comment or posting comments
  def matches?({:note_regex, regex}, %Context{transaction: transaction, posting: posting}) do
    # Check transaction comment
    txn_comment = get_in(transaction, [:comment]) || Map.get(transaction, "comment")
    txn_match = txn_comment != nil and Regex.match?(regex, txn_comment)

    # Check posting comments
    posting_comments = get_in(posting, [:comments]) || Map.get(posting, "comments") || []

    posting_match =
      Enum.any?(posting_comments, fn comment ->
        Regex.match?(regex, comment)
      end)

    txn_match or posting_match
  end

  # Has tag - checks if posting has a tag matching the pattern
  def matches?({:has_tag, regex}, %Context{posting: posting}) do
    tags = get_in(posting, [:tags]) || Map.get(posting, "tags") || []

    Enum.any?(tags, fn tag ->
      Regex.match?(regex, tag)
    end)
  end

  # Tag value - checks if posting has metadata key with matching value
  def matches?({:tag_value, key, regex}, %Context{posting: posting}) do
    metadata = get_in(posting, [:metadata]) || Map.get(posting, "metadata") || %{}
    value = Map.get(metadata, key)
    value != nil and Regex.match?(regex, to_string(value))
  end

  # Amount greater than
  def matches?({:amount_gt, threshold, currency}, %Context{posting: posting}) do
    compare_amount(posting, threshold, currency, &Decimal.gt?/2)
  end

  # Amount less than
  def matches?({:amount_lt, threshold, currency}, %Context{posting: posting}) do
    compare_amount(posting, threshold, currency, &Decimal.lt?/2)
  end

  # Amount equal
  def matches?({:amount_eq, threshold, currency}, %Context{posting: posting}) do
    compare_amount(posting, threshold, currency, &Decimal.eq?/2)
  end

  # Amount greater than or equal
  def matches?({:amount_gte, threshold, currency}, %Context{posting: posting}) do
    compare_amount(posting, threshold, currency, fn a, b ->
      Decimal.gt?(a, b) or Decimal.eq?(a, b)
    end)
  end

  # Amount less than or equal
  def matches?({:amount_lte, threshold, currency}, %Context{posting: posting}) do
    compare_amount(posting, threshold, currency, fn a, b ->
      Decimal.lt?(a, b) or Decimal.eq?(a, b)
    end)
  end

  # Logical AND
  def matches?({:and, left, right}, context) do
    matches?(left, context) and matches?(right, context)
  end

  # Logical OR
  def matches?({:or, left, right}, context) do
    matches?(left, context) or matches?(right, context)
  end

  # Logical NOT
  def matches?({:not, expr}, context) do
    not matches?(expr, context)
  end

  # ============================================================================
  # Convenience functions
  # ============================================================================

  @doc """
  Parses a predicate string and evaluates it against a context.

  Combines `Parser.parse/1` and `matches?/2` for convenience.
  """
  @spec evaluate(String.t(), Context.t()) :: {:ok, boolean()} | {:error, term()}
  def evaluate(predicate, context) when is_binary(predicate) do
    case Parser.parse(predicate) do
      {:ok, ast} ->
        {:ok, matches?(ast, context)}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Finds all postings in a transaction that match a predicate.

  Returns a list of `{posting, index}` tuples for matching postings.
  """
  @spec find_matching_postings(String.t() | ast(), map()) :: {:ok, [{map(), non_neg_integer()}]} | {:error, term()}
  def find_matching_postings(predicate, transaction) when is_binary(predicate) do
    case Parser.parse(predicate) do
      {:ok, ast} ->
        find_matching_postings(ast, transaction)

      {:error, _} = error ->
        error
    end
  end

  def find_matching_postings(ast, transaction) when is_tuple(ast) do
    postings = Map.get(transaction, :postings) || Map.get(transaction, "postings") || []

    matches =
      postings
      |> Enum.with_index()
      |> Enum.filter(fn {posting, index} ->
        ctx = context(transaction, posting, posting_index: index)
        matches?(ast, ctx)
      end)

    {:ok, matches}
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp compare_amount(posting, threshold, currency, comparator) do
    amount = get_in(posting, [:amount]) || Map.get(posting, "amount")

    if amount == nil do
      false
    else
      posting_value = Map.get(amount, :value) || Map.get(amount, "value")
      posting_currency = Map.get(amount, :currency) || Map.get(amount, "currency")

      # Currency must match if specified in predicate
      currency_matches = currency == nil or posting_currency == currency

      if currency_matches and posting_value != nil do
        # Ensure we're comparing Decimals
        posting_decimal = to_decimal(posting_value)
        threshold_decimal = to_decimal(threshold)
        comparator.(posting_decimal, threshold_decimal)
      else
        false
      end
    end
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)
end
