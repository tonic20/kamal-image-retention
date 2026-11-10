# frozen_string_literal: true

module KamalImageRetention
  module Releases
    COMMIT = /\A(?:[a-f0-9]{40}|[a-f0-9]{64})\z/

    def self.protected_tags(tags, count, used, repository)
      commits = tags.select { |tag, _| tag.match?(COMMIT) }.values.uniq
      keep = commits.sort_by { |id| [ yield(id), id ] }.last(count).to_set
      tags.each do |tag, id|
        keep << id if !tag.match?(COMMIT) || used.include?(id) || used.include?("#{repository}:#{tag}")
      end
      keep
    end

    def self.clean_build(host, repository, count, used, apply)
      ids = host.docker("image", "ls", "-aq", "--no-trunc", "--filter", "reference=#{repository}:*").split
      tags, dates = {}, {}
      host.inspect_rows("image", ids, "{{.Id}} {{.Created}} {{json .RepoTags}}").each do |row|
        id, date, aliases = row.split(" ", 3)
        dates[id] = Time.iso8601(date)
        Array(JSON.parse(aliases)).each do |ref|
          repo, _, tag = ref.rpartition(":")
          tags[tag] = id if repo == repository
        end
      end
      keep = protected_tags(tags, count, used, repository) { |id| dates.fetch(id) }
      old = tags.reject { |_, id| keep.include?(id) }
      if apply
        old.each do |tag, id|
          ref = "#{repository}:#{tag}"
          host.docker("image", "rm", ref) if host.docker("image", "inspect", "-f", "{{.Id}}", ref) == id
        end
      end
      old.size
    end
  end
end
