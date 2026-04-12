defmodule Expert.CodeIntelligence.Hex.Candidate do
  @moduledoc """
  Candidate structs emitted by `Expert.CodeIntelligence.Hex` for the three
  dependency tuple slots.
  """

  defmodule Package do
    @moduledoc false
    @enforce_keys [:name]
    defstruct [:name, :description, :latest_version, :downloads, :installed_version, :repo]

    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t() | nil,
            latest_version: String.t() | nil,
            downloads: non_neg_integer() | nil,
            installed_version: String.t() | nil,
            repo: String.t() | nil
          }
  end

  defmodule Version do
    @moduledoc false
    @enforce_keys [:package, :version]
    defstruct [:package, :version, :index, :prefix, :retirement]

    @type retirement :: %{
            reason: String.t(),
            message: String.t() | nil
          }

    @type t :: %__MODULE__{
            package: String.t(),
            version: String.t(),
            index: non_neg_integer(),
            prefix: String.t() | nil,
            retirement: retirement() | nil
          }
  end

  defmodule Opt do
    @moduledoc false
    @enforce_keys [:name]
    defstruct [:name, :description]

    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t() | nil
          }
  end
end
