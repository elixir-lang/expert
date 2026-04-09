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
            # The text the user has already typed inside the version
            # literal (e.g. `"~> 3"` for cursor at `"~> 3|`), used by the
            # completion translator to compute an explicit text-edit
            # range. `nil` when the candidate was constructed without
            # cursor context, in which case the translator falls back to
            # `Code.Fragment.cursor_context`-based insertion.
            prefix: String.t() | nil,
            # Retirement metadata for versions hex has marked retired —
            # `nil` for active releases. The `reason` is normalized into
            # one of `"invalid"`, `"renamed"`, `"security"`,
            # `"deprecated"`, `"other"`; `message` is whatever the
            # maintainer supplied on hex.pm.
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
