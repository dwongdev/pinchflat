defmodule Pinchflat.Downloading.MediaDownloadWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures

  alias Pinchflat.Media
  alias Pinchflat.Sources
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.Downloading.MediaDownloadWorker

  setup do
    stub(YtDlpRunnerMock, :run, fn
      _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
      _url, :download_thumbnail, _opts, _ot, _addl -> {:ok, ""}
      _url, :download, _opts, _ot, _addl -> {:ok, render_metadata(:media_metadata)}
    end)

    stub(UserScriptRunnerMock, :run, fn _event_type, _data -> {:ok, "", 0} end)
    stub(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, ""} end)

    media_item =
      %{media_filepath: nil}
      |> media_item_fixture()
      |> Repo.preload([:metadata, source: :media_profile])

    {:ok, %{media_item: media_item}}
  end

  describe "kickoff_with_task/2" do
    test "starts the worker", %{media_item: media_item} do
      assert [] = all_enqueued(worker: MediaDownloadWorker)
      assert {:ok, _} = MediaDownloadWorker.kickoff_with_task(media_item)
      assert [_] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "attaches a task", %{media_item: media_item} do
      assert {:ok, task} = MediaDownloadWorker.kickoff_with_task(media_item)
      assert task.media_item_id == media_item.id
    end

    test "can be called with additional job arguments", %{media_item: media_item} do
      job_args = %{"force" => true}

      assert {:ok, _} = MediaDownloadWorker.kickoff_with_task(media_item, job_args)

      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id, "force" => true})
    end

    test "has a priority of 5 by default", %{media_item: media_item} do
      assert {:ok, _} = MediaDownloadWorker.kickoff_with_task(media_item)

      [job] = all_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})

      assert job.priority == 5
    end

    test "priority can be set", %{media_item: media_item} do
      assert {:ok, _} = MediaDownloadWorker.kickoff_with_task(media_item, %{}, priority: 0)

      [job] = all_enqueued(worker: MediaDownloadWorker, args: %{"id" => media_item.id})

      assert job.priority == 0
    end
  end

  describe "perform/1" do
    setup do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:ok, render_metadata(:media_metadata)}
        _url, :download_thumbnail, _opts, _ot, _addl -> {:ok, ""}
      end)

      :ok
    end

    test "saves attributes to the media_item", %{media_item: media_item} do
      assert media_item.media_filepath == nil
      perform_job(MediaDownloadWorker, %{id: media_item.id})
      media_item = Repo.reload(media_item)

      assert media_item.media_filepath != nil
    end

    test "saves the metadata to the media_item", %{media_item: media_item} do
      assert media_item.metadata == nil
      perform_job(MediaDownloadWorker, %{id: media_item.id})
      assert Repo.reload(media_item).metadata != nil
    end

    test "won't double-schedule downloading jobs", %{media_item: media_item} do
      Oban.insert(MediaDownloadWorker.new(%{id: media_item.id}))
      Oban.insert(MediaDownloadWorker.new(%{id: media_item.id}))

      assert [_] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "sets the job to retryable if the download fails", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, "error"}
      end)

      Oban.Testing.with_testing_mode(:inline, fn ->
        {:ok, job} = Oban.insert(MediaDownloadWorker.new(%{id: media_item.id}))

        assert job.state == "retryable"
      end)
    end

    test "sets the job to retryable if the download failed and was retried", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, "Unable to communicate with SponsorBlock", 1}
      end)

      Oban.Testing.with_testing_mode(:inline, fn ->
        {:ok, job} = Oban.insert(MediaDownloadWorker.new(%{id: media_item.id}))

        assert job.state == "retryable"
      end)
    end

    test "does not set the job to retryable if retrying wouldn't fix the issue", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, "Something something Video unavailable something something", 1}
      end)

      Oban.Testing.with_testing_mode(:inline, fn ->
        {:ok, job} = Oban.insert(MediaDownloadWorker.new(%{id: media_item.id, quality_upgrade?: true}))

        assert job.state == "completed"
      end)
    end

    test "does not set the job to retryable if youtube thinks you're a bot", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, "Sign in to confirm you're not a bot", 1}
      end)

      Oban.Testing.with_testing_mode(:inline, fn ->
        {:ok, job} = Oban.insert(MediaDownloadWorker.new(%{id: media_item.id, quality_upgrade?: true}))

        assert job.state == "completed"
      end)
    end

    test "does not set the job to retryable you aren't a member", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, _addl ->
          {:error, "This video is available to this channel's members on level: foo", 1}
      end)

      Oban.Testing.with_testing_mode(:inline, fn ->
        {:ok, job} = Oban.insert(MediaDownloadWorker.new(%{id: media_item.id, quality_upgrade?: true}))

        assert job.state == "completed"
      end)
    end

    test "ensures error are returned in a 2-item tuple", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:error, "error", 1}
      end)

      assert {:error, :download_failed} = perform_job(MediaDownloadWorker, %{id: media_item.id})
    end

    test "does not download if the source is set to not download", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 0, fn _url, :download, _opts, _ot, _addl -> :ok end)

      Sources.update_source(media_item.source, %{download_media: false})

      perform_job(MediaDownloadWorker, %{id: media_item.id})
    end

    test "does not download if the media item is set to not download", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 0, fn _url, :download, _opts, _ot, _addl -> :ok end)

      Media.update_media_item(media_item, %{prevent_download: true})

      perform_job(MediaDownloadWorker, %{id: media_item.id})
    end

    test "saves the file's size to the database", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, _addl ->
          metadata = render_parsed_metadata(:media_metadata)
          FilesystemUtils.write_p!(metadata["filepath"], "test")

          {:ok, Phoenix.json_library().encode!(metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      perform_job(MediaDownloadWorker, %{id: media_item.id})
      media_item = Repo.reload(media_item)

      assert media_item.media_size_bytes > 0
    end

    test "does not set redownloaded_at by default", %{media_item: media_item} do
      perform_job(MediaDownloadWorker, %{id: media_item.id})
      media_item = Repo.reload(media_item)

      assert media_item.media_redownloaded_at == nil
    end

    test "does not blow up if the record doesn't exist" do
      assert :ok = perform_job(MediaDownloadWorker, %{id: 0})
    end

    test "sets the no_force_overwrites runner option", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, opts, _ot, _addl ->
          assert :no_force_overwrites in opts
          refute :force_overwrites in opts

          {:ok, render_metadata(:media_metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      perform_job(MediaDownloadWorker, %{id: media_item.id})
    end

    test "does not download if the media item isn't pending download", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 0, fn _url, :download, _opts, _ot, _addl -> :ok end)

      Media.update_media_item(media_item, %{media_filepath: "foo.mp4"})

      perform_job(MediaDownloadWorker, %{id: media_item.id})
    end
  end

  describe "perform/1 when testing non-downloadable media" do
    test "does not retry the job if the media is currently not downloadable", %{media_item: media_item} do
      stub(YtDlpRunnerMock, :run, fn _url, :get_downloadable_status, _opts, _ot, _addl ->
        {:ok, Phoenix.json_library().encode!(%{"live_status" => "is_live"})}
      end)

      Oban.Testing.with_testing_mode(:inline, fn ->
        {:ok, job} = Oban.insert(MediaDownloadWorker.new(%{id: media_item.id}))

        assert job.state == "completed"
      end)
    end
  end

  describe "perform/1 when testing forced downloads" do
    test "ignores 'prevent_download' if forced", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:ok, render_metadata(:media_metadata)}
        _url, :download_thumbnail, _opts, _ot, _addl -> {:ok, ""}
      end)

      Sources.update_source(media_item.source, %{download_media: false})
      Media.update_media_item(media_item, %{prevent_download: true})

      perform_job(MediaDownloadWorker, %{id: media_item.id, force: true})
    end

    test "ignores whether the media item is pending when forced", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:ok, render_metadata(:media_metadata)}
        _url, :download_thumbnail, _opts, _ot, _addl -> {:ok, ""}
      end)

      Media.update_media_item(media_item, %{media_filepath: "foo.mp4"})

      perform_job(MediaDownloadWorker, %{id: media_item.id, force: true})
    end

    test "sets force_overwrites runner option", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, opts, _ot, _addl ->
          assert :force_overwrites in opts
          refute :no_force_overwrites in opts

          {:ok, render_metadata(:media_metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      perform_job(MediaDownloadWorker, %{id: media_item.id, force: true})
    end
  end

  describe "perform/1 when testing re-downloads" do
    test "sets redownloaded_at on the media_item", %{media_item: media_item} do
      perform_job(MediaDownloadWorker, %{id: media_item.id, quality_upgrade?: true})
      media_item = Repo.reload(media_item)

      assert media_item.media_redownloaded_at != nil
    end

    test "ignores whether the media item is pending when re-downloaded", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl -> {:ok, "{}"}
        _url, :download, _opts, _ot, _addl -> {:ok, render_metadata(:media_metadata)}
        _url, :download_thumbnail, _opts, _ot, _addl -> {:ok, ""}
      end)

      Media.update_media_item(media_item, %{media_filepath: "foo.mp4"})

      perform_job(MediaDownloadWorker, %{id: media_item.id, quality_upgrade?: true})
    end

    test "doesn't redownload if the source is set to not download", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 0, fn _url, :download, _opts, _ot, _addl -> :ok end)

      Sources.update_source(media_item.source, %{download_media: false})

      perform_job(MediaDownloadWorker, %{id: media_item.id, quality_upgrade?: true})
    end

    test "doesn't redownload if the media item is set to not download", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 0, fn _url, :download, _opts, _ot, _addl -> :ok end)

      Media.update_media_item(media_item, %{prevent_download: true})

      perform_job(MediaDownloadWorker, %{id: media_item.id, quality_upgrade?: true})
    end

    test "sets force_overwrites runner option", %{media_item: media_item} do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, opts, _ot, _addl ->
          assert :force_overwrites in opts
          refute :no_force_overwrites in opts

          {:ok, render_metadata(:media_metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      perform_job(MediaDownloadWorker, %{id: media_item.id, force: true})
    end

    test "deletes old files if the media item has been updated" do
      expect(YtDlpRunnerMock, :run, 3, fn
        _url, :get_downloadable_status, _opts, _ot, _addl ->
          {:ok, "{}"}

        _url, :download, _opts, _ot, _addl ->
          tmp_media_item = media_item_with_attachments()
          metadata = render_parsed_metadata(:media_metadata)
          metadata = Map.put(metadata, "filepath", tmp_media_item.media_filepath)

          {:ok, Phoenix.json_library().encode!(metadata)}

        _url, :download_thumbnail, _opts, _ot, _addl ->
          {:ok, ""}
      end)

      old_media_item = media_item_with_attachments()
      perform_job(MediaDownloadWorker, %{id: old_media_item.id, force: true})
      updated_media_item = Repo.reload(old_media_item)

      assert updated_media_item.media_filepath != old_media_item.media_filepath
      refute File.exists?(old_media_item.media_filepath)
      assert File.exists?(updated_media_item.media_filepath)
    end
  end

  describe "perform/1 when testing user script callbacks" do
    test "calls the media_pre_download user script runner", %{media_item: media_item} do
      expect(UserScriptRunnerMock, :run, fn :media_pre_download, data ->
        assert data.id == media_item.id

        {:ok, "", 0}
      end)

      expect(UserScriptRunnerMock, :run, fn :media_downloaded, _ -> {:ok, "", 0} end)

      perform_job(MediaDownloadWorker, %{id: media_item.id})
    end

    test "does not download the media if the pre-download script returns an error", %{media_item: media_item} do
      expect(UserScriptRunnerMock, :run, fn :media_pre_download, _ -> {:ok, "", 1} end)

      assert :ok = perform_job(MediaDownloadWorker, %{id: media_item.id})
      media_item = Repo.reload!(media_item)

      refute media_item.media_filepath
      assert media_item.prevent_download
    end

    test "downloads media if the pre-download script is not present", %{media_item: media_item} do
      expect(UserScriptRunnerMock, :run, fn :media_pre_download, _ -> {:ok, :no_executable} end)
      expect(UserScriptRunnerMock, :run, fn :media_downloaded, _ -> {:ok, :no_executable} end)

      assert :ok = perform_job(MediaDownloadWorker, %{id: media_item.id})
      media_item = Repo.reload!(media_item)

      assert media_item.media_filepath
      refute media_item.prevent_download
    end

    test "calls the media_downloaded user script runner", %{media_item: media_item} do
      expect(UserScriptRunnerMock, :run, fn :media_pre_download, _ -> {:ok, "", 0} end)

      expect(UserScriptRunnerMock, :run, fn :media_downloaded, data ->
        assert data.id == media_item.id

        {:ok, "", 0}
      end)

      perform_job(MediaDownloadWorker, %{id: media_item.id})
    end
  end
end
