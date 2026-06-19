defmodule MobDev.GooglePlayTest do
  use ExUnit.Case, async: true

  alias MobDev.GooglePlay

  describe "needs_changes_not_sent_for_review?/1" do
    test "true for the real Play 400 body that demands the flag" do
      msg =
        "HTTP 400: Changes cannot be sent for review automatically. Please set " <>
          "the query parameter changesNotSentForReview to true. Once committed, " <>
          "the changes in this edit can be sent for review from the Google Play Console UI."

      assert GooglePlay.needs_changes_not_sent_for_review?(msg)
    end

    test "false for an unrelated commit failure" do
      refute GooglePlay.needs_changes_not_sent_for_review?(
               "HTTP 403: The caller does not have permission"
             )
    end

    test "false for an empty message" do
      refute GooglePlay.needs_changes_not_sent_for_review?("")
    end
  end
end
