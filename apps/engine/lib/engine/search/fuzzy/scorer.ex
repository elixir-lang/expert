defmodule Engine.Search.Fuzzy.Scorer do
  @moduledoc """
  Scores a match based on heuristics.

  The goal of this module is to have a quick to build and fast to query fuzzy matching system.

  Matches match a subject based on a pattern given by the user. A string is considered to match
  if the subject contains all of the pattern's characters, in any order. However, patterns
  can be boosted based on heuristics.

  The heuristics boost:
    1. Larger patterns
    2. Patterns that match more consecutive characters
    3. Patterns that match the beginning of the subject
    4. Patterns that match the case of the subject
    5. Patterns that match the tail of a subject starting at the last period

  Based loosely on https://medium.com/@Srekel/implementing-a-fuzzy-search-algorithm-for-the-debuginator-cacc349e6c55
  """
  defstruct match?: false,
            index: 0,
            matched_character_positions: []

  import Record

  defrecord :subject, graphemes: nil, normalized: nil, period_positions: [-1]

  @typedoc "A match score. Higher numbers mean a more relevant match."
  @type score :: integer
  @type score_result :: {match? :: boolean(), score}
  @type subject :: term()
  @type pattern :: String.t()
  @type preprocessed ::
          record(:subject, graphemes: tuple(), normalized: String.t())
  @non_match_score -5000

  @doc """
  Pre-processes a subject into separate parts that will be helpful during the search phase.
  Pre-processing allows us to do the work of extracting important metadata per-subject
  rather than on every request.
  """
  @spec preprocess(subject()) :: preprocessed()
  def preprocess(subject) when is_binary(subject) do
    graphemes =
      subject
      |> String.graphemes()
      |> List.to_tuple()

    normalized = normalize(subject)

    subject(
      graphemes: graphemes,
      normalized: normalized,
      period_positions: period_positions(normalized)
    )
  end

  def preprocess(subject) do
    subject
    |> inspect()
    |> preprocess()
  end

  @doc """
  Scores the pattern based on the subject

  Returns a two-element tuple, where the first element is a boolean representing if the
  pattern matches the subject. The second element is the score of the match. Higher
  scores mean a better match. Scores can be negative.
  """
  @spec score(subject(), pattern()) :: score_result()
  def score(subject, pattern) when is_binary(subject) do
    subject
    |> preprocess()
    |> score(pattern)
  end

  def score(subject(normalized: normalized) = subject, pattern) do
    normalized_pattern = normalize(pattern)

    case collect_scores(normalized, normalized_pattern) do
      [] ->
        {false, @non_match_score}

      elems ->
        max_score =
          elems
          |> Enum.map(&calculate_score(&1, subject, pattern))
          |> Enum.max()

        {true, max_score}
    end
  end

  defp collect_scores(normalized, normalized_pattern, starting_index \\ 0, acc \\ [])

  defp collect_scores(normalized_subject, normalized_pattern, starting_index, scores) do
    # we collect scores because it's possible that a better match occurs later
    # in the subject, and if we start peeling off characters greedily, we'll miss
    # it. This is more expensive, but it's still pretty quick.

    initial_score = %__MODULE__{index: starting_index}

    case do_score(normalized_subject, normalized_pattern, initial_score) do
      %__MODULE__{match?: true, matched_character_positions: [pos | _]} = score ->
        slice_start = pos + 1
        next_index = starting_index + slice_start
        subject_substring = String.slice(normalized_subject, slice_start..-1//1)
        scores = [score | scores]
        collect_scores(subject_substring, normalized_pattern, next_index, scores)

      _ ->
        scores
    end
  end

  # out of pattern, we have a match.
  defp do_score(_, <<>>, %__MODULE__{} = score) do
    %__MODULE__{
      score
      | match?: true,
        matched_character_positions: Enum.reverse(score.matched_character_positions)
    }
  end

  # we're out of subject, but we still have pattern, no match
  defp do_score(<<>>, _, %__MODULE__{} = score) do
    %__MODULE__{
      score
      | matched_character_positions: Enum.reverse(score.matched_character_positions)
    }
  end

  defp do_score(
         <<match::utf8, subject_rest::binary>>,
         <<match::utf8, pattern_rest::binary>>,
         %__MODULE__{} = score
       ) do
    score =
      score
      |> add_to_list(:matched_character_positions, score.index)
      |> increment(:index)

    do_score(subject_rest, pattern_rest, score)
  end

  defp do_score(<<_unmatched::utf8, subject_rest::binary>>, pattern, %__MODULE__{} = score) do
    score = increment(score, :index)

    do_score(subject_rest, pattern, score)
  end

  defp increment(%__MODULE__{} = score, field_name) do
    Map.update!(score, field_name, &(&1 + 1))
  end

  defp add_to_list(%__MODULE__{} = score, field_name, value) do
    Map.update(score, field_name, [value], &[value | &1])
  end

  defp calculate_score(%__MODULE__{match?: false}, _, _) do
    @non_match_score
  end

  defp calculate_score(%__MODULE__{} = score, subject(graphemes: graphemes) = subject, pattern) do
    pattern_length = String.length(pattern)

    {consecutive_count, consecutive_bonus} =
      consecutive_match_boost(score.matched_character_positions)

    match_amount_boost = consecutive_count * pattern_length

    match_boost = tail_match_boost(score, subject, pattern_length)

    camel_case_boost = camel_case_boost(score.matched_character_positions, subject)

    mismatched_penalty = mismatched_penalty(score.matched_character_positions)

    incompleteness_penalty = tuple_size(graphemes) - length(score.matched_character_positions)

    consecutive_bonus + match_boost + camel_case_boost +
      match_amount_boost - mismatched_penalty - incompleteness_penalty
  end

  defp normalize(string) do
    String.downcase(string)
  end

  @tail_match_boost 55

  defp tail_match_boost(
         %__MODULE__{} = score,
         subject(graphemes: graphemes, period_positions: period_positions),
         pattern_length
       ) do
    [first_match_position | _] = score.matched_character_positions

    match_end = first_match_position + pattern_length
    subject_length = tuple_size(graphemes)

    if MapSet.member?(period_positions, first_match_position - 1) and match_end == subject_length do
      # reward a complete match at the end of the last period. This is likely a module
      # and the pattern matches the most local parts
      @tail_match_boost
    else
      0
    end
  end

  @consecutive_character_bonus 15

  def consecutive_match_boost(matched_positions) do
    # This function checks for consecutive matched characters, and
    # makes matches with more consecutive matched characters worth more.
    # This means if I type En, it will match Enum more than it will match
    # Something

    max_streak =
      matched_positions
      |> Enum.reduce([[]], fn
        current, [[last | streak] | rest] when last == current - 1 ->
          [[current, last | streak] | rest]

        current, acc ->
          [[current] | acc]
      end)
      |> Enum.max_by(&length/1)

    streak_length = length(max_streak)
    {streak_length, @consecutive_character_bonus * streak_length}
  end

  @mismatched_chracter_penalty 5

  def mismatched_penalty(matched_positions) do
    {penalty, _} =
      matched_positions
      |> Enum.reduce({0, -1}, fn
        matched_position, {0, _} ->
          # only start counting the penalty after the first match,
          # otherwise we will inadvertently penalize matches deeper in the string
          {0, matched_position}

        matched_position, {penalty, last_match} ->
          distance = matched_position - last_match

          {penalty + distance * @mismatched_chracter_penalty, matched_position}
      end)

    penalty
  end

  @camel_case_boost 5
  defp camel_case_boost(matched_positions, subject(graphemes: graphemes)) do
    graphemes
    |> Tuple.to_list()
    |> camel_positions()
    |> Enum.reduce(0, fn position, score ->
      if position in matched_positions do
        score + @camel_case_boost
      else
        score
      end
    end)
  end

  defp camel_positions(graphemes) do
    camel_positions(graphemes, {nil, :lower}, 0, [])
  end

  defp camel_positions([], _, _, positions) do
    Enum.reverse(positions)
  end

  defp camel_positions([grapheme | rest], {_last_char, :lower}, position, positions) do
    case case_of(grapheme) do
      :lower ->
        camel_positions(rest, {grapheme, :lower}, position + 1, positions)

      :upper ->
        camel_positions(rest, {grapheme, :upper}, position + 1, [position | positions])
    end
  end

  defp camel_positions([grapheme | rest], {_last_char, :upper}, position, positions) do
    camel_positions(rest, {grapheme, case_of(grapheme)}, position + 1, positions)
  end

  defp case_of(grapheme) do
    if String.downcase(grapheme) == grapheme do
      :lower
    else
      :upper
    end
  end

  defp period_positions(string) do
    period_positions(string, 0, [-1])
  end

  defp period_positions(<<>>, _, positions), do: MapSet.new(positions)

  defp period_positions(<<".", rest::binary>>, position, positions) do
    period_positions(rest, position + 1, [position | positions])
  end

  defp period_positions(<<_::utf8, rest::binary>>, position, positions) do
    period_positions(rest, position + 1, positions)
  end
end
