defmodule KilnCMS.Organize.Vectors do
  @moduledoc """
  The little vector arithmetic `KilnCMS.Organize` does in the BEAM (#1596):
  normalize, dot, mean, and a deterministic spherical k-means.

  Plain lists, no Nx: Nx ships only with the opt-in ML build (`KILN_ML=1`),
  and everything here must run on the lean one — a deployment can point
  `KilnCMS.Search` at a remote embedder and turn semantic search on without
  compiling the local model stack. The sizes are bounded by
  `KilnCMS.Organize.bounds/0`, and the costs at those bounds are measured in
  the callers' moduledocs.

  Every vector passed in is assumed non-zero; `normalize/1` maps a zero vector
  to itself rather than dividing by zero.
  """

  @doc "Unit-length copy of `v`."
  @spec normalize([float()]) :: [float()]
  def normalize(v) do
    norm = :math.sqrt(dot(v, v))
    if norm == 0.0, do: v, else: Enum.map(v, &(&1 / norm))
  end

  @doc "Dot product. For unit vectors, cosine similarity (distance = 1 − dot)."
  @spec dot([float()], [float()]) :: float()
  def dot(a, b), do: dot(a, b, 0.0)

  defp dot([x | xs], [y | ys], acc), do: dot(xs, ys, acc + x * y)
  defp dot([], [], acc), do: acc

  @doc "Element-wise mean of a non-empty list of equal-length vectors."
  @spec mean([[float()]]) :: [float()]
  def mean([first | _] = vectors) do
    n = length(vectors)
    zero = Enum.map(first, fn _ -> 0.0 end)

    vectors
    |> Enum.reduce(zero, &add/2)
    |> Enum.map(&(&1 / n))
  end

  defp add(a, b), do: add(a, b, [])
  defp add([x | xs], [y | ys], acc), do: add(xs, ys, [x + y | acc])
  defp add([], [], acc), do: Enum.reverse(acc)

  @max_iterations 10

  @doc """
  Spherical k-means over `points` — `[{key, unit_vector}]` — into at most `k`
  groups. Returns `[{center, [key]}]`, members nearest-first, largest group
  first.

  Deterministic, so a page reload shows the same clusters: points are ordered
  by key, the first center is the point most similar to the global mean, and
  each next one is the point least similar to every center chosen so far
  (farthest-point seeding — no random restarts to disagree with each other).
  At most #{@max_iterations} assignment rounds, stopping early when nothing
  moves.
  """
  @spec kmeans([{term(), [float()]}], pos_integer()) :: [{[float()], [term()]}]
  def kmeans([], _k), do: []

  def kmeans(points, k) do
    points = Enum.sort_by(points, &elem(&1, 0))
    k = min(k, length(points))
    centers = seed(points, k)

    points
    |> iterate(centers, nil, @max_iterations)
    |> groups(points)
  end

  defp seed(points, k) do
    global = points |> Enum.map(&elem(&1, 1)) |> mean() |> normalize()
    {_key, first} = Enum.max_by(points, fn {_key, v} -> dot(v, global) end)

    Enum.reduce(2..k//1, [first], fn _i, centers ->
      {_key, next} =
        Enum.min_by(points, fn {_key, v} -> centers |> Enum.map(&dot(v, &1)) |> Enum.max() end)

      centers ++ [next]
    end)
  end

  defp iterate(_points, centers, assignment, 0), do: {centers, assignment}

  defp iterate(points, centers, previous, rounds) do
    assignment = Enum.map(points, fn {_key, v} -> nearest(v, centers) end)

    if assignment == previous do
      {centers, assignment}
    else
      iterate(points, recenter(points, assignment, centers), assignment, rounds - 1)
    end
  end

  defp nearest(v, centers) do
    centers
    |> Enum.with_index()
    |> Enum.max_by(fn {c, _i} -> dot(v, c) end)
    |> elem(1)
  end

  # An emptied cluster keeps its old center rather than collapsing — it may
  # win points back next round, and if not it is dropped from the result.
  defp recenter(points, assignment, centers) do
    members = points |> Enum.zip(assignment) |> Enum.group_by(&elem(&1, 1), &elem(elem(&1, 0), 1))

    centers
    |> Enum.with_index()
    |> Enum.map(fn {center, i} ->
      case Map.get(members, i) do
        nil -> center
        vectors -> vectors |> mean() |> normalize()
      end
    end)
  end

  defp groups({centers, assignment}, points) do
    points
    |> Enum.zip(assignment)
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.map(fn {i, members} ->
      center = Enum.at(centers, i)

      keys =
        members
        |> Enum.sort_by(fn {key, v} -> {-dot(v, center), key} end)
        |> Enum.map(&elem(&1, 0))

      {center, keys}
    end)
    |> Enum.sort_by(fn {_center, keys} -> {-length(keys), hd(keys)} end)
  end
end
