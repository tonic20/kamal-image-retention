Gem::Specification.new do |spec|
  spec.name = "kamal-image-retention"
  spec.version = "0.1.1"
  spec.summary = "Retain recent Kamal builds on the build machine and in a private Distribution registry"
  spec.authors = ["Anton Kopylov"]
  spec.homepage = "https://github.com/tonic20/kamal-image-retention"
  spec.license = "Nonstandard"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md"]
  spec.bindir = "exe"
  spec.executables = ["kamal-retain-images"]
  spec.add_dependency "kamal", "~> 2.12"
end
