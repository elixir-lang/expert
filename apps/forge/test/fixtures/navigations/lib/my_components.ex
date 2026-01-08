defmodule MyComponents do
  @moduledoc """
  Example Phoenix components module for testing ~H sigil handling.
  This module provides components that can be used with shorthand notation.
  """

  use Component

  @doc """
  A simple button component.
  """
  def button(assigns) do
    ~H"""
    <button class="btn"><%= render_slot(@inner_block) %></button>
    """
  end

  @doc """
  A table component with slots for columns.
  """
  def table(assigns) do
    ~H"""
    <table>
      <thead>
        <tr>
          <%= for col <- @col do %>
            <th><%= col.header %></th>
          <% end %>
        </tr>
      </thead>
      <tbody>
        <%= for row <- @rows do %>
          <tr>
            <%= for col <- @col do %>
              <td><%= render_slot(col, row) %></td>
            <% end %>
          </tr>
        <% end %>
      </tbody>
    </table>
    """
  end
end
