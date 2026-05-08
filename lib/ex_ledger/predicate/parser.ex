defmodule ExLedger.Predicate.Parser do
  @moduledoc """
  Parser for ledger automated transaction predicates.

  Parses predicate strings like:
  - `/Expenses:Food/` - account regex
  - `payee =~ /Grocery/` - payee regex match
  - `note =~ /reimbursable/` - note regex match
  - `has_tag(/business/)` - tag existence check
  - `tag("Project") =~ /Alpha/` - tag value match
  - `amount > $100` - amount comparison
  - `expr and expr` - logical AND
  - `expr or expr` - logical OR
  - `( expr )` - grouping

  Returns an AST that can be evaluated by `ExLedger.Predicate.Evaluator`.
  """

  import NimbleParsec

  @type ast ::
          {:account_regex, Regex.t()}
          | {:payee_regex, Regex.t()}
          | {:note_regex, Regex.t()}
          | {:has_tag, Regex.t()}
          | {:tag_value, String.t(), Regex.t()}
          | {:amount_gt, Decimal.t(), String.t() | nil}
          | {:amount_lt, Decimal.t(), String.t() | nil}
          | {:amount_eq, Decimal.t(), String.t() | nil}
          | {:and, ast(), ast()}
          | {:or, ast(), ast()}
          | {:not, ast()}

  # ============================================================================
  # Basic building blocks
  # ============================================================================

  whitespace = ascii_string([?\s, ?\t], min: 1)
  optional_whitespace = ascii_string([?\s, ?\t], min: 0)

  # ============================================================================
  # Regex pattern: /pattern/
  # ============================================================================

  # Match content inside /.../, handling escaped forward slashes
  regex_char =
    choice([
      string("\\/") |> replace(?/),
      utf8_char([not: ?/])
    ])

  regex_pattern =
    ignore(string("/"))
    |> repeat(regex_char)
    |> ignore(string("/"))
    |> reduce({:chars_to_string, []})

  # ============================================================================
  # Account regex: /pattern/
  # Bare regex matches against account names
  # ============================================================================

  account_regex =
    regex_pattern
    |> unwrap_and_tag(:account_pattern)
    |> post_traverse({:build_account_regex, []})

  # ============================================================================
  # Payee match: payee =~ /pattern/
  # ============================================================================

  payee_match =
    ignore(string("payee"))
    |> ignore(optional_whitespace)
    |> ignore(string("=~"))
    |> ignore(optional_whitespace)
    |> concat(regex_pattern |> unwrap_and_tag(:payee_pattern))
    |> post_traverse({:build_payee_regex, []})

  # ============================================================================
  # Note match: note =~ /pattern/
  # ============================================================================

  note_match =
    ignore(string("note"))
    |> ignore(optional_whitespace)
    |> ignore(string("=~"))
    |> ignore(optional_whitespace)
    |> concat(regex_pattern |> unwrap_and_tag(:note_pattern))
    |> post_traverse({:build_note_regex, []})

  # ============================================================================
  # Has tag: has_tag(/pattern/)
  # ============================================================================

  has_tag =
    ignore(string("has_tag"))
    |> ignore(optional_whitespace)
    |> ignore(string("("))
    |> ignore(optional_whitespace)
    |> concat(regex_pattern |> unwrap_and_tag(:tag_pattern))
    |> ignore(optional_whitespace)
    |> ignore(string(")"))
    |> post_traverse({:build_has_tag, []})

  # ============================================================================
  # Tag value match: tag("key") =~ /pattern/
  # ============================================================================

  quoted_string =
    ignore(string("\""))
    |> utf8_string([not: ?"], min: 1)
    |> ignore(string("\""))

  tag_value_match =
    ignore(string("tag"))
    |> ignore(optional_whitespace)
    |> ignore(string("("))
    |> ignore(optional_whitespace)
    |> concat(quoted_string |> unwrap_and_tag(:tag_key))
    |> ignore(optional_whitespace)
    |> ignore(string(")"))
    |> ignore(optional_whitespace)
    |> ignore(string("=~"))
    |> ignore(optional_whitespace)
    |> concat(regex_pattern |> unwrap_and_tag(:tag_value_pattern))
    |> post_traverse({:build_tag_value, []})

  # ============================================================================
  # Amount comparison: amount > $100, amount < 50 EUR, amount == $25
  # ============================================================================

  # Currency symbol or code
  currency_symbol =
    utf8_char([?$, ?€, ?£, ?¥, ?₹, ?₽, ?₿, ?₩, ?฿, ?₪, ?₴, ?₦, ?₱, ?₡, ?₲, ?₵, ?₭, ?₮, ?¢])
    |> reduce({:char_to_string, []})

  currency_code = ascii_string([?A..?Z], min: 1, max: 5)

  currency =
    choice([
      currency_symbol,
      currency_code
    ])

  # Amount number
  decimal_digits = ascii_string([?0..?9], min: 1)

  amount_number =
    decimal_digits
    |> unwrap_and_tag(:integer_part)
    |> optional(
      ignore(string("."))
      |> concat(decimal_digits |> unwrap_and_tag(:decimal_part))
    )
    |> reduce({:build_number, []})

  # Amount with optional leading or trailing currency
  amount_leading_currency =
    currency
    |> unwrap_and_tag(:currency)
    |> ignore(optional_whitespace)
    |> concat(amount_number |> unwrap_and_tag(:value))

  amount_trailing_currency =
    amount_number
    |> unwrap_and_tag(:value)
    |> ignore(whitespace)
    |> concat(currency |> unwrap_and_tag(:currency))

  amount_bare =
    amount_number
    |> unwrap_and_tag(:value)

  amount_value =
    choice([
      amount_leading_currency,
      amount_trailing_currency,
      amount_bare
    ])
    |> reduce({:extract_amount, []})

  # Comparison operators
  comparison_op =
    choice([
      string(">=") |> replace(:gte),
      string("<=") |> replace(:lte),
      string("==") |> replace(:eq),
      string(">") |> replace(:gt),
      string("<") |> replace(:lt)
    ])

  amount_comparison =
    ignore(string("amount"))
    |> ignore(optional_whitespace)
    |> concat(comparison_op |> unwrap_and_tag(:op))
    |> ignore(optional_whitespace)
    |> concat(amount_value |> unwrap_and_tag(:amount))
    |> post_traverse({:build_amount_comparison, []})

  # ============================================================================
  # Primary expressions (atoms)
  # ============================================================================

  # Order matters - more specific patterns first
  primary =
    choice([
      payee_match,
      note_match,
      has_tag,
      tag_value_match,
      amount_comparison,
      account_regex
    ])

  # ============================================================================
  # Grouping: ( expr )
  # ============================================================================

  # Forward declaration for recursive parsing
  defcombinatorp(
    :grouped_expr,
    ignore(string("("))
    |> ignore(optional_whitespace)
    |> parsec(:or_expr)
    |> ignore(optional_whitespace)
    |> ignore(string(")"))
  )

  atom =
    choice([
      parsec(:grouped_expr),
      primary
    ])

  # ============================================================================
  # NOT expression: not expr
  # ============================================================================

  not_expr =
    choice([
      ignore(string("not"))
      |> ignore(whitespace)
      |> concat(atom)
      |> post_traverse({:build_not, []}),
      atom
    ])

  # ============================================================================
  # AND expression: expr and expr
  # ============================================================================

  and_op =
    ignore(whitespace)
    |> ignore(string("and"))
    |> ignore(whitespace)

  defcombinatorp(
    :and_expr,
    not_expr
    |> repeat(
      and_op
      |> concat(not_expr)
    )
    |> reduce({:build_and_chain, []})
  )

  # ============================================================================
  # OR expression: expr or expr (lowest precedence)
  # ============================================================================

  or_op =
    ignore(whitespace)
    |> ignore(string("or"))
    |> ignore(whitespace)

  defcombinatorp(
    :or_expr,
    parsec(:and_expr)
    |> repeat(
      or_op
      |> concat(parsec(:and_expr))
    )
    |> reduce({:build_or_chain, []})
  )

  # ============================================================================
  # Top-level parser
  # ============================================================================

  defparsec(
    :predicate_parser,
    ignore(optional_whitespace)
    |> concat(parsec(:or_expr))
    |> ignore(optional_whitespace)
    |> eos()
  )

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Parses a predicate string into an AST.

  Returns `{:ok, ast}` on success, `{:error, reason}` on failure.

  ## Examples

      iex> Parser.parse("/Expenses:Food/")
      {:ok, {:account_regex, ~r/Expenses:Food/}}

      iex> Parser.parse("payee =~ /Grocery/")
      {:ok, {:payee_regex, ~r/Grocery/}}

      iex> Parser.parse("/Expenses:/ and payee =~ /Grocery/")
      {:ok, {:and, {:account_regex, ~r/Expenses:/}, {:payee_regex, ~r/Grocery/}}}
  """
  @spec parse(String.t()) :: {:ok, ast()} | {:error, term()}
  def parse(input) when is_binary(input) do
    case predicate_parser(input) do
      {:ok, [ast], "", _, _, _} ->
        {:ok, ast}

      {:ok, _, rest, _, _, _} ->
        {:error, {:unexpected_input, rest}}

      {:error, reason, rest, _, line, column} ->
        {:error, {:parse_error, reason, rest, line, column}}
    end
  end

  @doc """
  Parses a predicate string, raising on failure.
  """
  @spec parse!(String.t()) :: ast()
  def parse!(input) when is_binary(input) do
    case parse(input) do
      {:ok, ast} -> ast
      {:error, reason} -> raise ArgumentError, "Failed to parse predicate: #{inspect(reason)}"
    end
  end

  # ============================================================================
  # Helper functions for parsing
  # ============================================================================

  defp chars_to_string(chars) when is_list(chars) do
    chars
    |> Enum.map(fn
      c when is_integer(c) -> <<c::utf8>>
      s when is_binary(s) -> s
    end)
    |> Enum.join()
  end

  defp char_to_string([codepoint]) when is_integer(codepoint) do
    <<codepoint::utf8>>
  end

  defp build_number(parts) do
    integer_part = Keyword.get(parts, :integer_part)
    decimal_part = Keyword.get(parts, :decimal_part)

    number_str =
      if decimal_part do
        integer_part <> "." <> decimal_part
      else
        integer_part
      end

    Decimal.new(number_str)
  end

  defp extract_amount(parts) do
    value = Keyword.get(parts, :value)
    currency = Keyword.get(parts, :currency)
    {value, currency}
  end

  # ============================================================================
  # Post-traverse functions for building AST nodes
  # ============================================================================

  defp build_account_regex(rest, [{:account_pattern, pattern}], context, _line, _offset) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        {rest, [{:account_regex, regex}], context}

      {:error, reason} ->
        {:error, {:invalid_regex, pattern, reason}}
    end
  end

  defp build_payee_regex(rest, [{:payee_pattern, pattern}], context, _line, _offset) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        {rest, [{:payee_regex, regex}], context}

      {:error, reason} ->
        {:error, {:invalid_regex, pattern, reason}}
    end
  end

  defp build_note_regex(rest, [{:note_pattern, pattern}], context, _line, _offset) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        {rest, [{:note_regex, regex}], context}

      {:error, reason} ->
        {:error, {:invalid_regex, pattern, reason}}
    end
  end

  defp build_has_tag(rest, [{:tag_pattern, pattern}], context, _line, _offset) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        {rest, [{:has_tag, regex}], context}

      {:error, reason} ->
        {:error, {:invalid_regex, pattern, reason}}
    end
  end

  defp build_tag_value(
         rest,
         [{:tag_value_pattern, pattern}, {:tag_key, key}],
         context,
         _line,
         _offset
       ) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        {rest, [{:tag_value, key, regex}], context}

      {:error, reason} ->
        {:error, {:invalid_regex, pattern, reason}}
    end
  end

  defp build_amount_comparison(
         rest,
         [{:amount, {value, currency}}, {:op, op}],
         context,
         _line,
         _offset
       ) do
    ast_node =
      case op do
        :gt -> {:amount_gt, value, currency}
        :lt -> {:amount_lt, value, currency}
        :eq -> {:amount_eq, value, currency}
        :gte -> {:amount_gte, value, currency}
        :lte -> {:amount_lte, value, currency}
      end

    {rest, [ast_node], context}
  end

  defp build_not(rest, [expr], context, _line, _offset) do
    {rest, [{:not, expr}], context}
  end

  defp build_and_chain([single]), do: single

  defp build_and_chain([first | rest]) do
    Enum.reduce(rest, first, fn right, left ->
      {:and, left, right}
    end)
  end

  defp build_or_chain([single]), do: single

  defp build_or_chain([first | rest]) do
    Enum.reduce(rest, first, fn right, left ->
      {:or, left, right}
    end)
  end
end
