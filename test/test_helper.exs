ExUnit.start()

defmodule ExLedger.TestHelpers do
  import ExUnit.Assertions
  import ExUnit.Callbacks

  def find_executable!(name) do
    System.find_executable(name) || flunk("#{name} executable not found")
  end

  def require_executable(name) do
    case System.find_executable(name) do
      nil -> {:skip, "#{name} executable not available"}
      executable -> {:ok, executable}
    end
  end

  def tmp_dir!(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    dir
  end

  @doc """
  Compares two amount values, handling Decimal vs float comparisons.
  Returns true if values are equal (within precision).
  """
  def amount_eq?(nil, nil), do: true
  def amount_eq?(nil, _), do: false
  def amount_eq?(_, nil), do: false

  def amount_eq?(%Decimal{} = d, expected) when is_float(expected) do
    Decimal.eq?(d, Decimal.from_float(expected))
  end

  def amount_eq?(%Decimal{} = d, expected) when is_integer(expected) do
    Decimal.eq?(d, Decimal.new(expected))
  end

  def amount_eq?(%Decimal{} = d1, %Decimal{} = d2) do
    Decimal.eq?(d1, d2)
  end

  def amount_eq?(actual, expected) when is_float(actual) and is_float(expected) do
    abs(actual - expected) < 0.0001
  end

  def amount_eq?(actual, expected), do: actual == expected

  @doc """
  Creates a Decimal from a float value for test assertions.
  """
  def decimal(n) when is_float(n), do: Decimal.from_float(n)
  def decimal(n) when is_integer(n), do: Decimal.new(n)
  def decimal(n) when is_binary(n), do: Decimal.new(n)

  @doc """
  Asserts that an amount map matches the expected values.
  The `value` field is compared using Decimal.eq? for precision.
  """
  def assert_amount(%{value: actual_value} = actual, %{value: expected_value} = expected) do
    import ExUnit.Assertions

    # Compare value using Decimal.eq?
    assert amount_eq?(actual_value, expected_value),
           "Expected value #{inspect(expected_value)}, got #{inspect(actual_value)}"

    # Compare other fields
    expected_without_value = Map.delete(expected, :value)
    actual_without_value = Map.delete(actual, :value)

    for {key, expected_val} <- expected_without_value do
      assert Map.get(actual_without_value, key) == expected_val,
             "Expected #{key} to be #{inspect(expected_val)}, got #{inspect(Map.get(actual, key))}"
    end

    true
  end

  def assert_amount(actual, expected) do
    import ExUnit.Assertions
    assert actual == expected
  end
end
