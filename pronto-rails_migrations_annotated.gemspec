# frozen_string_literal: true

require_relative "lib/pronto/rails_migrations_annotated/version"

Gem::Specification.new do |spec|
  spec.name = "pronto-rails_migrations_annotated"
  spec.version = Pronto::RailsMigrationsAnnotatedVersion::VERSION
  spec.authors = ["Vasily Fedoseyev"]
  spec.email = ["vasilyfedoseyev@gmail.com"]

  spec.summary = "Pronto runner to check rails migrations to be separate from other code, but allow annotations"
  spec.description = <<~TEXT
    For project stability it's a common practive to release db migrations separated from other code changes.
    This pronto runner helps to enforce this. Also checks other migration PR basic sanity things.
  TEXT
  spec.homepage = "https://github.com/Vasfed/pronto-rails_migrations_annotated"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.5.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/Vasfed/pronto-rails_migrations_annotated"
  # spec.metadata["changelog_uri"] = "TODO: Put CHANGELOG.md URL here once there's a changelog"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == __FILE__) || f.match(%r{\A(?:(?:bin|test|spec|features)/|\.(?:git|travis|circleci)|appveyor)})
    end
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "pronto", "~>0.11"
end
