defmodule Formatter.Config do
  def quokka do
    [
      only: [
        # Changes to blocks of code
        :blocks,
        # Fixes for imports, aliases, etc.
        :module_directives,
        # Various fixes for pipes
        :pipes,
        # Inefficient function rewrites
        :single_node
      ]
    ]
  end
end
