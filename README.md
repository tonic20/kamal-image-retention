# Kamal image retention

Kamal prunes old containers and images on your application servers. A copy of each
release can still take up disk space on the machine that built it and in your
Docker registry. This gem cleans up those copies for one Kamal application at a
time. Run it manually or from a hook after each deploy.

## Installation

Add the gem to the Gemfile you use to run Kamal. It requires Ruby 3.2 or newer
and declares a dependency on Kamal `~> 2.12`.

```ruby
group :deploy, optional: true do
  gem "kamal-image-retention", "~> 0.1.1", require: false
end
```

On the machine where you run deployments, enable the group and install it:

```sh
bundle config set --local with deploy
bundle install
```

The command needs local Docker access and SSH access to Docker on the app hosts.
It reads the image name, registry, hosts and SSH settings from the same Kamal
configuration you use to deploy.

## Preview a cleanup

From the application's Kamal directory, run:

```sh
bundle exec kamal-retain-images -d staging
```

Use your destination name, or omit `-d staging` if you deploy with just
`config/deploy.yml`. Pass `-c FILE` if you keep the base config elsewhere.
The preview counts eligible tags without removing images. Example output for
an application with a supported registry:

```text
registry.example.com/team/app registry {"obsolete_tags":3}
registry.example.com/team/app build machine {"obsolete_tags":2}
```

Here, three registry tags and two local tags are eligible for removal. To apply
the cleanup to the same destination, run:

```sh
bundle exec kamal-retain-images -d staging --apply
```

## What gets kept

The gem keeps the five newest distinct builds tagged with a full Git SHA, ordered
by image creation time. To change the count, set Kamal's existing option in
`config/deploy.yml` or a destination override:

```yaml
retain_containers: 8
```

Images with a named tag such as `stable` and images referenced by running or
stopped containers on the build machine or the configured app hosts are also
kept. For example, if `stable` points to the eighth-newest build and your limit
is five, that build survives alongside the newest five. Shared registry layers
stay available to the other repositories that use them.

## Run after each deployment

Add this block to your executable `.kamal/hooks/post-deploy` shell script.
If you are creating the file, start it with `#!/bin/sh` and run
`chmod +x .kamal/hooks/post-deploy` once.

```sh
case "${KAMAL_COMMAND:-}" in
  deploy|redeploy)
    bundle exec kamal-retain-images --apply
    ;;
esac
```

The hook inherits `KAMAL_DESTINATION` from Kamal. Each invocation runs once
and exits. [Kamal hook documentation](https://kamal-deploy.org/docs/hooks/overview/)

## Registry support

Registry cleanup supports a Kamal-managed `kamal-docker-registry` container
running Distribution v3 with a single Docker volume at `/var/lib/registry` and
its default configuration. The registry can run locally on the build machine
or on an app host selected for the deployment. With a hosted registry such as
GHCR, the gem cleans up the build machine and leaves registry retention to the
provider.

When registry cleanup has work to do, pushes and pulls to **all repositories
on that registry** pause during collection. A recent upload defers collection.
If collection is interrupted, rerun with `--apply` from the same build machine
and user account so the gem can read its recovery state.

## Development

```sh
bundle install
bundle exec ruby -Ilib test/retention_test.rb
```

## Changelog

See the [release history](CHANGELOG.md).

## License

[MIT License](LICENSE.txt)

## Author

Built by [Anton Kopylov](https://www.kopylov.net).
