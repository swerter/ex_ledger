defmodule ExLedger.ParseContext do
  @moduledoc """
  Context struct for tracking state during ledger file parsing with includes.
  """

  defstruct [:base_dir, :seen_files, :source_file, :import_chain, :accounts, :transactions]

  @type t :: %__MODULE__{
          base_dir: String.t(),
          seen_files: MapSet.t(String.t()),
          source_file: String.t() | nil,
          import_chain: [{String.t(), non_neg_integer()}] | nil,
          accounts: %{String.t() => atom()},
          transactions: [map()]
        }
end
