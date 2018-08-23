defmodule RepoPoller.Repository.Service do
  alias Domain.Repos.Repo
  alias Domain.Tags.Tag

  @spec get_tags(module(), Repo.t()) ::
          {:ok, list(Tag.t())} | {:error, :rate_limit, pos_integer()} | {:error, map()}
  def get_tags(adapter, repo) do
    adapter.get_tags(repo)
  end
end
