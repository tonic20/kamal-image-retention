# Changelog

## Unreleased

- Show the installed command name in `kamal-retain-images --help`.
- Added the MIT license and changelog to the gem package.

## 0.1.1 — 2026-11-10

- First release on RubyGems.org. Applications can install the gem by name.
- Documented how to preview cleanup, configure the retention count and run the command after a deployment.

## 0.1.0 — 2026-11-10

- Initial Git release of `kamal-retain-images`. The command previews and removes obsolete release tags for one application on the build machine and in a Kamal-managed Distribution v3 registry.
- Uses Kamal's `retain_containers` setting and preserves named tags and images referenced by existing containers.
