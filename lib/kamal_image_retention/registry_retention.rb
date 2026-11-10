# frozen_string_literal: true

module KamalImageRetention
  class RegistryRetention
    ROOT = "/var/lib/registry/docker/registry/v2/repositories"
    DIGEST = /\Asha256:[0-9a-f]{64}\z/

    def initialize(host, repository, port, state, container: "kamal-docker-registry")
      @host, @repo, @port, @state, @container = host, repository, port, state, container
      @helper = "#{container}-retention"
      @marker = state.join("restore-registry")
      @journal = state.join("pending-#{Digest::SHA256.hexdigest(repository)}.json")
    end

    def metadata(container)
      script = <<~'SH'
        cd "$1"
        find . -path '*/_manifests/revisions/*/*/link'
        find . -path '*/_manifests/tags/*/current/link' -exec sh -ec '
          for path do printf "%s %s\n" "$path" "$(cat "$path")"; done' sh {} +
      SH
      data = {}
      @host.docker("exec", container, "sh", "-ec", script, "sh", ROOT).each_line do |line|
        path, digest = line.split
        repo, link = path.delete_prefix("./").split("/_manifests/", 2)
        item = data[repo] ||= { tags: {}, revisions: Set.new }
        if digest
          item[:tags][link.split("/").fetch(1)] = digest
        else
          _, algorithm, hex, = link.split("/")
          item[:revisions] << "#{algorithm}:#{hex}"
        end
      end
      data
    end

    def with_api(port, &block)
      @host.with_port(port) { |local| RegistryAPI.new(local).open(&block) }
    end

    def graph(roots, children)
      found = Set.new
      pending = roots.to_a.dup
      until pending.empty?
        id = pending.pop
        pending.concat(children.fetch(id)) if found.add?(id)
      end
      found
    end

    def plan(api, entry, count, used, reference, pending)
      tags, revisions = entry.values_at(:tags, :revisions)
      manifests = revisions.to_h { |id| [ id, JSON.parse(api.content("#{@repo}/manifests/#{id}", id)) ] }
      children = manifests.transform_values do |m|
        raise "Unsupported manifest" unless m.key?("config") || m.key?("manifests")
        (m.fetch("manifests", []) + [ m["subject"] ].compact).map { |c| c.fetch("digest") }
      end
      dates = {}
      created = lambda do |id|
        dates[id] ||= begin
          m = manifests.fetch(id)
          if m["config"]
            cfg = m["config"].fetch("digest")
            Time.iso8601(JSON.parse(api.content("#{@repo}/blobs/#{cfg}", cfg)).fetch("created"))
          else
            m.fetch("manifests").reject { |c| c.dig("platform", "architecture") == "unknown" }
              .map { |c| created.call(c.fetch("digest")) }.max || raise("Missing image creation time")
          end
        end
      end
      pins = manifests.keys.select { |id| used.include?(id) || used.include?(manifests[id].dig("config", "digest")) }.to_set
      keep = Releases.protected_tags(tags, count, used, reference, &created)
      tags.each_value { |id| keep << id if graph([ id ], children).intersect?(pins) }
      candidates = graph((tags.values.to_set - keep) | (pending & revisions), children)
      live = graph((revisions - candidates) | keep | pins, children)
      obsolete = (candidates - live).sort_by { |id| -graph([ id ], children).size }
      blobs = obsolete.to_set
      obsolete.each do |id|
        m = manifests.fetch(id)
        (m.fetch("layers", []) + [ m["config"] ].compact).each { |blob| blobs << blob.fetch("digest") }
      end
      [ obsolete, blobs ]
    end

    def verify(api, metadata)
      metadata.each do |repo, entry|
        blobs = Set.new
        entry[:revisions].each do |id|
          m = JSON.parse(api.content("#{repo}/manifests/#{id}", id))
          (m.fetch("manifests", []) + [ m["subject"] ].compact).each do |child|
            raise "Missing manifest in #{repo}" unless entry[:revisions].include?(child.fetch("digest"))
          end
          (m.fetch("layers", []) + [ m["config"] ].compact).each { |b| blobs << b.fetch("digest") }
        end
        blobs.each { |id| api.request("#{repo}/blobs/#{id}", "HEAD") }
        entry[:tags].each { |tag, id| api.content("#{repo}/manifests/#{tag}", id) }
      end
    end

    def uploads?(container)
      !@host.docker("exec", container, "sh", "-ec", 'find "$1" -mmin -15 -path "*/_uploads/*" | head -1', "sh", ROOT).empty?
    end

    def sweep(image, candidates)
      args = [ "run", "--rm", "--pull=never", "--network=none", "--volumes-from" ]
      report = @host.docker(*args, "#{@container}:ro", "-e", "REGISTRY_LOG_LEVEL=error", "--entrypoint", "/bin/registry",
        image, "garbage-collect", "--dry-run", "/etc/distribution/config.yml")
      raise "Unexpected Distribution GC report" unless report.match?(/\d+ blobs marked, \d+ blobs and \d+ manifests eligible for deletion/)
      eligible = report.scan(/^blob eligible for deletion: (sha256:\h{64})$/).flatten.to_set
      links = report.scan(/^layer link eligible for deletion: #{Regexp.escape(@repo)}\/(sha256:\h{64})$/).flatten.to_set
      foreign = @host.docker(*args, "#{@container}:ro", "--entrypoint", "sh", image, "-ec",
        'cd "$1" && find . -path "./$2/_layers" -prune -o -path "*/_layers/sha256/*/link" -print', "sh", ROOT, @repo)
      shared = foreign.lines.map { |line| "sha256:#{line.split("/")[-2]}" }.to_set
      paths = []
      candidates.each do |id|
        raise "Invalid digest" unless id.match?(DIGEST)
        hex = id.delete_prefix("sha256:")
        paths << "repositories/#{@repo}/_layers/sha256/#{hex}/link" if links.include?(id)
        paths << "blobs/sha256/#{hex[0, 2]}/#{hex}/data" if eligible.include?(id) && !shared.include?(id)
      end
      paths.each_slice(100) do |batch|
        @host.docker(*args, @container, "--entrypoint", "sh", image, "-ec",
          'cd /var/lib/registry/docker/registry/v2 && rm -f "$@"', "sh", *batch)
      end
    end

    def write_state(path, value)
      tmp = path.sub_ext(".tmp")
      tmp.write(JSON.generate(value))
      tmp.rename(path)
    end

    def recover
      return unless @marker.exist?
      id, helper = JSON.parse(@marker.read)
      raise "Registry identity changed" unless @host.docker("inspect", "-f", "{{.Id}}", @container) == id
      existing = @host.docker("ps", "-aq", "--no-trunc", "--filter", "id=#{helper}")
      @host.docker("rm", "-f", helper) unless existing.empty?
      @host.docker("start", id)
      @marker.delete
    end

    def clean(reference, count, used, apply, directory)
      recover if apply
      ports = JSON.parse(@host.docker("inspect", "-f", "{{json .NetworkSettings.Ports}}", @container))
      bound = Array(ports["5000/tcp"]).any? { |p| p["HostPort"] == @port.to_s && %w[127.0.0.1 0.0.0.0].include?(p["HostIp"]) }
      raise "Unexpected registry port binding" unless bound
      initial = metadata(@container)
      entry = initial.fetch(@repo, { tags: {}, revisions: Set.new })
      pending = @journal.exist? ? JSON.parse(@journal.read) : { "revisions" => [], "blobs" => [] }
      obsolete, candidates = with_api(@port) { |api| plan(api, entry, count, used, reference, pending.fetch("revisions").to_set) }
      summary = { obsolete_tags: entry[:tags].count { |_, id| obsolete.include?(id) } }
      return summary unless apply && (obsolete.any? || @journal.exist?)
      return summary.merge(deferred: "active upload") if uploads?(@container)

      id, image, mounts, env = @host.docker("inspect", "-f",
        '{{.Id}} {{.Image}} {{json .Mounts}}{{println}}{{json .Config.Env}}', @container).match(/\A(\S+) (\S+) (.+)\n(.+)\z/).captures
      mount, *others = JSON.parse(mounts)
      raise "Unexpected registry storage" unless others.empty? && mount&.values_at("Type", "Destination") == [ "volume", "/var/lib/registry" ]
      raise "Custom registry configuration" if JSON.parse(env).any? { |v| v.start_with?("REGISTRY_") }
      raise "Expected Distribution v3" unless @host.docker("exec", id, "registry", "--version").match?(%r{distribution/v3 3\.})
      before = @host.docker("exec", id, "du", "-sk", "/var/lib/registry").split.first.to_i
      helper = @host.docker("create", "--name", @helper, "--volumes-from", id, "-p", "127.0.0.1::5000", "--pull=never", image)
      begin
        write_state(@marker, [ id, helper ])
      rescue StandardError
        @host.docker("rm", helper)
        raise
      end
      begin
        @host.docker("stop", id)
        @host.docker("start", helper)
        port = Integer(@host.docker("port", helper, "5000/tcp").rpartition(":").last)
        @host.check_deploy_lock(directory)
        return summary.merge(deferred: "registry changed during scan") if uploads?(helper) || metadata(helper) != initial
        candidates.merge(pending.fetch("blobs"))
        write_state(@journal, revisions: obsolete, blobs: candidates.to_a)
        with_api(port) do |api|
          obsolete.each { |digest| api.request("#{@repo}/manifests/#{digest}", "DELETE") }
          entry[:tags].delete_if { |_, digest| obsolete.include?(digest) }
          entry[:revisions].subtract(obsolete)
          raise "Unexpected revision changes" unless metadata(helper) == initial
          verify(api, initial)
        end
        @host.docker("stop", helper)
        sweep(image, candidates)
      ensure
        recover
      end
      raise "Unexpected revisions after collection" unless metadata(@container) == initial
      with_api(@port) { |api| verify(api, initial) }
      @journal.delete
      after = @host.docker("exec", id, "du", "-sk", "/var/lib/registry").split.first.to_i
      summary.merge(freed_bytes: (before - after) * 1024, retained_tags: entry[:tags].size)
    end
  end
end
