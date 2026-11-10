# frozen_string_literal: true

module KamalImageRetention
  class DockerHost
    def initialize(host = nil, ssh = nil)
      @host, @ssh = host, ssh
    end

    def open
      return yield self unless @host
      Net::SSH.start(@host, @ssh.user, **@ssh.options.except(:user)) do |session|
        @session = session
        yield self
      ensure
        @session = nil
      end
    end

    def run(*args)
      if @session
        output = +""
        errors = +""
        status = {}
        @session.exec!(args.shelljoin, status: status) do |_, stream, data|
          (stream == :stdout ? output : errors) << data
        end
        success = status[:exit_code] == 0
      else
        env = ENV.to_h.slice("HOME", "PATH", "DOCKER_CONFIG", "DOCKER_CONTEXT", "DOCKER_HOST", "SSH_AUTH_SOCK")
        output, errors, status = Open3.capture3(env, *args, unsetenv_others: true)
        success = status.success?
      end
      raise "#{args.first} failed on #{@host || "local"}: #{errors.strip}" unless success
      output.chomp
    end

    def docker(*args) = run("docker", *args)

    def inspect_rows(kind, ids, format)
      return [] if ids.empty?
      docker(kind, "inspect", "-f", format, *ids.uniq).lines(chomp: true)
    end

    def check_deploy_lock(directory)
      run("sh", "-ec", 'case "$1" in /*) dir=$1;; *) dir="$HOME/$1";; esac; for lock in "$dir"/lock-*; do [ ! -d "$lock" ] || exit 1; done', "sh", directory)
    end

    def inventory(directory)
      check_deploy_lock(directory)
      used = Set.new
      ids = docker("ps", "-aq", "--no-trunc").split
      rows = inspect_rows("container", ids, "{{.Image}} {{.Config.Image}}")
      images = rows.map do |row|
        digest, reference = row.split
        used.merge([ digest, reference, reference.split("@").last ])
        digest
      end
      inspect_rows("image", images, "{{.Id}} {{json .RepoDigests}}").each do |row|
        digest, references = row.split(" ", 2)
        used << digest
        Array(JSON.parse(references)).each { |r| used << r.split("@").last }
      end
      used
    end

    def with_port(port)
      return yield port unless @host
      # The SSH event loop must continue servicing HTTP while the command session runs Docker.
      Net::SSH.start(@host, @ssh.user, **@ssh.options.except(:user)) do |tunnel|
        local_port = tunnel.forward.local(0, "127.0.0.1", port)
        done = false
        thread = Thread.new { tunnel.loop(0.1) { !done } }
        begin
          yield local_port
        ensure
          done = true
          thread.join
        end
      end
    end
  end
end
