# Kamal image retention

Run `bundle exec kamal-retain-images` from the application's Kamal directory for a preview. Pass `-d staging` or `-d production` for a named destination. The post-deploy hook passes `--apply` after a successful deployment.

The command loads the application's resolved Kamal config, including destination overrides, SSH settings, image, registry and retention count. It keeps the most recent distinct SHA-tagged builds (five by default), named tags and images used by containers. Kamal handles application host pruning. The command cleans the build machine and the project's releases in a filesystem-backed Distribution v3 registry managed by Kamal. During collection the registry briefly stops serving pushes and pulls. A pending cleanup is retried on the next run.

Applications can install the gem from a pinned Git tag in an optional Bundler group, using their existing Kamal dependency. On the build machine, install the group with `BUNDLE_WITH=deploy bundle install`.

Run tests with `bundle exec ruby -Ilib test/retention_test.rb`.

## Author

Built by [Anton Kopylov](https://www.kopylov.net).
