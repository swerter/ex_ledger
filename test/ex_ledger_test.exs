defmodule ExLedgerTest do
  use ExUnit.Case
  doctest ExLedger

  test "greets the world" do
    assert ExLedger.hello() == :world
  end
end
