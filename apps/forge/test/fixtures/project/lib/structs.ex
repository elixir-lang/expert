defmodule Project.Structs do
  defmodule User do
    defstruct [:first_name, :last_name, :email_address]

    @type t :: %__MODULE__{
            first_name: String.t(),
            last_name: String.t(),
            email_address: String.t()
          }
  end

  defmodule Account do
    defstruct user: nil, last_login_at: nil

    @type t :: %__MODULE__{
            user: User.t()
          }
  end

  defmodule Order do
    @type t :: %__MODULE__{
            id: integer(),
            lines: [Line.t()]
          }
    defstruct [:id, :lines]

    defmodule Line do
      @type t :: %__MODULE__{
              id: integer(),
              product_id: integer(),
              quantity: integer()
            }
      defstruct [:id, :product_id, :quantity]
    end
  end

  defmodule NotAStruct do
  end
end
