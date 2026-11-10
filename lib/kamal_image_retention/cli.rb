# frozen_string_literal: true

module KamalImageRetention
  module CLI
    def self.run(argv)
      destination = ENV["KAMAL_DESTINATION"].presence
      config_file = "config/deploy.yml"
      apply = false
      OptionParser.new do |opts|
        opts.banner = "Usage: bin/retain-images [-d destination] [-c config_file] [--apply]"
        opts.on("-d DESTINATION") { |value| destination = value }
        opts.on("-c FILE") { |value| config_file = value }
        opts.on("--apply") { apply = true }
      end.parse!(argv)
      abort "Unexpected argument: #{argv.first}" unless argv.empty?

      config = Kamal::Configuration.create_from(config_file: Pathname(config_file), destination: destination)
      abort "Kamal service differs from hook" if ENV["KAMAL_SERVICE"].present? && ENV["KAMAL_SERVICE"] != config.service
      selected = ENV.fetch("KAMAL_HOSTS", "").split(",")
      abort "Hook hosts differ from configuration" unless (selected - config.all_hosts).empty?
      deployed = selected.empty? ? config.app_hosts : config.app_hosts & selected
      return if deployed.empty?

      local = DockerHost.new
      hosts = config.app_hosts.to_h { |host| [ host, DockerHost.new(host, config.ssh) ] }
      endpoint = URI.parse("http://#{config.registry.server}") if config.registry.server.present?
      registry_host = endpoint&.hostname unless config.registry.local?
      state = Pathname(Dir.home).join(".cache", "docker-release-retention")
      state.mkpath
      state.join("coordinator.lock").open("a") do |lock|
        lock.flock(File::LOCK_EX)
        used = local.inventory(config.run_directory)
        hosts.each_value { |h| h.open { used.merge(h.inventory(config.run_directory)) } }
        if endpoint && (registry_host.nil? || deployed.include?(registry_host))
          host = registry_host ? hosts.fetch(registry_host) : local
          registry_state = state.join(Digest::SHA256.hexdigest(config.registry.server))
          registry_state.mkpath
          host.open do
            retention = RegistryRetention.new(host, config.image, endpoint.port, registry_state)
            summary = retention.clean(config.repository, config.retain_containers, used, apply, config.run_directory)
            puts "#{config.repository} registry #{summary.to_json}"
          end
        end
        old = Releases.clean_build(local, config.repository, config.retain_containers, used, apply)
        puts "#{config.repository} build machine #{ { obsolete_tags: old }.to_json}"
      end
    end
  end
end
