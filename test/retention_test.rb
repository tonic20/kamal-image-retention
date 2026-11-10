# frozen_string_literal: true

require "minitest/autorun"
require "kamal_image_retention"

class ImageRetentionTest < Minitest::Test
  def test_build_keeps_named_and_in_use_images_and_counts_distinct_builds
    tags = (1..8).to_h { |i| [ "%040x" % i, i ] }
    tags["f" * 40] = 8
    tags["stable"] = 1
    used = Set["registry/app:%040x" % 2, 3]
    keep = KamalImageRetention::Releases.protected_tags(tags, 3, used, "registry/app") { |id| id }
    assert_equal Set[1, 2, 3, 6, 7, 8], keep
  end

  def test_build_only_removes_tags_from_the_selected_repository
    docker = Object.new
    calls = []
    docker.define_singleton_method(:docker) do |*args|
      calls << args
      args[1] == "inspect" ? "old" : "old new"
    end
    docker.define_singleton_method(:inspect_rows) do |*|
      [ %Q(old 2026-01-01T00:00:00Z ["reg/app:#{"a" * 40}","reg/other:#{"a" * 40}"]),
        %Q(new 2026-02-01T00:00:00Z ["reg/app:#{"b" * 40}"]) ]
    end
    assert_equal 1, KamalImageRetention::Releases.clean_build(docker, "reg/app", 1, Set.new, true)
    assert_equal [ [ "image", "rm", "reg/app:#{"a" * 40}" ] ], calls.select { |args| args[1] == "rm" }
  end

  def test_registry_protects_container_platforms_and_digest_only_indexes
    tags = (1..8).to_h { |i| [ "%040x" % i, "release#{i}" ] }
    manifests = tags.values.to_h { |id| [ id, { "config" => { "digest" => "cfg#{id.delete_prefix("release")}" } } ] }
    manifests["release2"] = { "manifests" => [ { "digest" => "platform" } ] }
    manifests["platform"] = { "config" => { "digest" => "cfg2" } }
    manifests["untagged"] = { "manifests" => [ { "digest" => "release3" } ] }
    api = Object.new
    api.define_singleton_method(:content) do |path, id|
      if path.include?("/blobs/")
        { created: "2026-01-%02dT00:00:00Z" % id.delete_prefix("cfg").to_i }.to_json
      else
        manifests.fetch(id).to_json
      end
    end
    retention = KamalImageRetention::RegistryRetention.new(nil, "team/app", 5000, Pathname("/unused"))
    old, blobs = retention.plan(api, { tags: tags, revisions: manifests.keys.to_set }, 3, Set["cfg2"], "registry/team/app", Set.new)
    assert_equal %w[release1 release4 release5].sort, old.sort
    assert_includes blobs, "cfg1"
    refute_includes blobs, "cfg2"
  end
end
