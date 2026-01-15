defmodule ExLedgerTest do
  use ExUnit.Case

  describe "format_date/1" do
    test "formats date with zero-padded components" do
      assert ExLedger.format_date(~D[2009-01-02]) == "09-Jan-02"
    end

    test "formats date using month names" do
      assert ExLedger.format_date(~D[2024-12-31]) == "24-Dec-31"
    end
  end

  describe "format_amount/1" do
    test "formats positive amounts with padding" do
      assert ExLedger.format_amount(4.5) == "    $4.50"
    end

    test "formats negative amounts with sign" do
      assert ExLedger.format_amount(-4.5) == "   -$4.50"
    end

    test "formats integer amounts" do
      assert ExLedger.format_amount(20) == "   $20.00"
    end
  end

  describe "format_ledger/1" do
    test "parses and formats ledger content" do
      input = """
      2024/01/01 Opening
          Assets:Cash  $10.00
          Equity:Opening
      """

      assert {:ok, output} = ExLedger.format_ledger(input)

      assert output ==
               "2024/01/01 Opening\n    Assets:Cash  $10.00\n    Equity:Opening  $-10.00\n"
    end
  end
end
