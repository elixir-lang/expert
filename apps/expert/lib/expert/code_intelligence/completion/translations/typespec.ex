defmodule Expert.CodeIntelligence.Completion.Translations.Typespec do
  alias Expert.CodeIntelligence.Completion.Translatable
  alias Expert.CodeIntelligence.Completion.Translations.Callable
  alias Forge.Ast.Env
  alias Forge.Completion.Candidate

  defimpl Translatable, for: Candidate.Typespec do
    def translate(typespec, _builder, %Env{} = env) do
      Callable.completion(typespec, env)
    end
  end
end
