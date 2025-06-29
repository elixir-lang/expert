defmodule NormalStruct do
  defstruct [:variant]
end

defmodule TypedStructs do
  use MacroStruct

  typedstruct enforce: true, module: MacroBasedStruct do
    field(:contract_id, String.t())
  end
end
