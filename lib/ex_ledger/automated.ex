defmodule ExLedger.Automated do
  @moduledoc """
  Applies automated transactions to generate derived postings.

  Automated transactions are rules that match against regular transactions
  and generate additional postings or add metadata/tags.

  ## Example

      = /Expenses:Food/
          (Budget:Food)  -1

  This rule matches any posting to an `Expenses:Food` account and generates
  a virtual unbalanced posting to `Budget:Food` with the negated amount.

  ## Usage

      {:ok, result} = LedgerParser.parse_ledger(input)
      transactions = Automated.apply_all(result.transactions)

  ## How it works

  1. Separates automated transactions (kind: :automated) from regular ones
  2. For each regular transaction:
     - For each posting in the transaction:
       - For each automated transaction:
         - Parse the predicate (cached)
         - Evaluate predicate against the posting
         - If match: generate derived postings OR apply metadata/tags
  3. Returns transactions with derived postings added

  ## Matching behavior

  - Predicates are evaluated at the **posting level**
  - Each matching posting can trigger generation of new postings
  - Automated transactions do NOT chain (no recursion)
  - Multiple automated transactions apply in file order
  """

  alias ExLedger.Predicate.{Parser, Evaluator, AmountExpr}

  @type transaction :: map()
  @type posting :: map()

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Applies all automated transactions to regular transactions.

  Takes a list of all transactions (both regular and automated) and returns
  a new list with derived postings added to matching regular transactions.

  Automated transactions are filtered out from the result.
  """
  @spec apply_all([transaction()]) :: [transaction()]
  def apply_all(transactions) do
    {automated, regular} = Enum.split_with(transactions, &automated?/1)

    # Parse all predicates upfront
    parsed_automated = Enum.map(automated, &parse_automated/1)

    # Apply to each regular transaction
    Enum.map(regular, fn txn ->
      apply_automated_transactions(txn, parsed_automated)
    end)
  end

  @doc """
  Applies automated transactions and returns both regular and automated.

  Unlike `apply_all/1`, this preserves automated transactions in the output.
  """
  @spec apply_all_preserve_automated([transaction()]) :: [transaction()]
  def apply_all_preserve_automated(transactions) do
    {automated, regular} = Enum.split_with(transactions, &automated?/1)
    parsed_automated = Enum.map(automated, &parse_automated/1)

    applied_regular =
      Enum.map(regular, fn txn ->
        apply_automated_transactions(txn, parsed_automated)
      end)

    regular_by_id =
      Map.new(applied_regular, fn txn ->
        {Map.fetch!(txn, :transaction_id), txn}
      end)

    # Maintain original order
    Enum.map(transactions, fn txn ->
      if automated?(txn) do
        txn
      else
        Map.get(regular_by_id, Map.get(txn, :transaction_id), txn)
      end
    end)
  end

  @doc """
  Checks if a transaction is an automated transaction.
  """
  @spec automated?(transaction()) :: boolean()
  def automated?(%{kind: :automated}), do: true
  def automated?(_), do: false

  # ============================================================================
  # Internal functions
  # ============================================================================

  defp parse_automated(auto_txn) do
    predicate = Map.get(auto_txn, :predicate)

    ast =
      case Parser.parse(predicate) do
        {:ok, ast} -> ast
        {:error, _} -> nil
      end

    Map.put(auto_txn, :parsed_predicate, ast)
  end

  defp apply_automated_transactions(transaction, automated_txns) do
    postings = Map.get(transaction, :postings, [])

    # For each posting, check all automated transactions
    {updated_postings, derived_postings} =
      postings
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {posting, index}, acc_derived ->
        {enriched_posting, new_derived} =
          apply_to_posting(transaction, posting, index, automated_txns)

        {enriched_posting, Enum.reverse(new_derived, acc_derived)}
      end)

    # Add derived postings to transaction
    derived_postings = Enum.reverse(derived_postings)
    all_postings = updated_postings ++ derived_postings

    transaction
    |> Map.put(:postings, all_postings)
    |> Map.put(:derived_postings, derived_postings)
  end

  defp apply_to_posting(transaction, posting, index, automated_txns) do
    ctx = Evaluator.context(transaction, posting, posting_index: index)

    Enum.reduce(automated_txns, {posting, []}, fn auto, {current_posting, derived} ->
      ast = Map.get(auto, :parsed_predicate)

      if ast != nil and Evaluator.matches?(ast, ctx) do
        case process_automated(auto, current_posting, transaction) do
          {:enrich, enriched_posting} ->
            {enriched_posting, derived}

          {:generate, new_postings} ->
            {current_posting, Enum.reverse(new_postings, derived)}

          {:both, enriched_posting, new_postings} ->
            {enriched_posting, Enum.reverse(new_postings, derived)}
        end
      else
        {current_posting, derived}
      end
    end)
  end

  defp process_automated(auto, matched_posting, _transaction) do
    auto_postings = Map.get(auto, :postings, [])

    # Separate metadata-only "postings" from real postings
    {metadata_only, real_postings} =
      Enum.split_with(auto_postings, &metadata_only_posting?/1)

    # Extract enrichment data from metadata-only postings
    enrichment = extract_enrichment(metadata_only)

    # Generate new postings from real postings
    generated =
      Enum.map(real_postings, fn auto_posting ->
        generate_posting(auto_posting, matched_posting, auto)
      end)

    # Apply enrichment to matched posting
    enriched_posting = apply_enrichment(matched_posting, enrichment)

    cond do
      enrichment != %{} and generated != [] ->
        {:both, enriched_posting, generated}

      enrichment != %{} ->
        {:enrich, enriched_posting}

      generated != [] ->
        {:generate, generated}

      true ->
        {:generate, []}
    end
  end

  defp metadata_only_posting?(posting) do
    # A metadata-only posting has no account or is explicitly marked as enrichment_only
    account = Map.get(posting, :account)
    enrichment_only = Map.get(posting, :enrichment_only, false)
    enrichment_only or account == nil or account == ""
  end

  defp extract_enrichment(metadata_postings) do
    Enum.reduce(metadata_postings, %{tags: [], metadata: %{}}, fn posting, acc ->
      tags = Map.get(posting, :tags, [])
      metadata = Map.get(posting, :metadata, %{})

      %{
        tags: acc.tags ++ tags,
        metadata: Map.merge(acc.metadata, metadata)
      }
    end)
  end

  defp apply_enrichment(posting, %{tags: [], metadata: meta}) when meta == %{} do
    posting
  end

  defp apply_enrichment(posting, enrichment) do
    existing_tags = Map.get(posting, :tags, [])
    existing_metadata = Map.get(posting, :metadata, %{})

    # Merge tags (avoid duplicates)
    new_tags = Enum.uniq(existing_tags ++ enrichment.tags)

    # Merge metadata
    new_metadata = Map.merge(existing_metadata, enrichment.metadata)

    posting
    |> Map.put(:tags, new_tags)
    |> Map.put(:metadata, new_metadata)
  end

  defp generate_posting(auto_posting, matched_posting, auto_txn) do
    matched_amount = Map.get(matched_posting, :amount)
    auto_amount = Map.get(auto_posting, :amount)

    # Evaluate amount expression
    result_amount = AmountExpr.evaluate(auto_amount, matched_amount)

    # Build the generated posting
    %{
      account: Map.get(auto_posting, :account),
      amount: result_amount,
      virtual: Map.get(auto_posting, :virtual, false),
      must_balance: Map.get(auto_posting, :must_balance, false),
      tags: Map.get(auto_posting, :tags, []),
      comments: Map.get(auto_posting, :comments, []),
      metadata:
        Map.get(auto_posting, :metadata, %{})
        |> Map.put("Generated_by", generate_rule_id(auto_txn)),
      cost: nil,
      actual_date: nil,
      effective_date: nil,
      assertion: nil,
      generated: true
    }
  end

  defp generate_rule_id(auto_txn) do
    # Use rule_id from metadata if present, otherwise use predicate
    metadata = Map.get(auto_txn, :metadata, %{})

    case Map.get(metadata, "rule_id") || Map.get(metadata, :rule_id) do
      nil -> Map.get(auto_txn, :predicate, "automated")
      rule_id -> rule_id
    end
  end
end
