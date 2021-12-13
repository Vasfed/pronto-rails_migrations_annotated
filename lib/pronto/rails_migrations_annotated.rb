# frozen_string_literal: true

require 'pronto'
require_relative "rails_migrations_annotated/version"

module Pronto
  class RailsMigrationsAnnotated < Runner
    VERSION = Pronto::RailsMigrationsAnnotatedVersion::VERSION

    def run
      @messages = []

      check_migrations_mixed_with_code
      check_migration_version_numbers
      check_large_schema_diff

      @messages
    end

    # todo: override def self.title ?

    private

    def add_message_at_patch(patches, message, level = :warning, line: :first)
      patches = [patches] unless patches.is_a?(Array)
      patches.each do |patch|
        target_line = case line
        when :first then patch.added_lines.first || patch.lines.first
        when :last then patch.added_lines.last || patch.lines.last
        else line
        end

        @messages << Message.new(
          patch.delta.new_file[:path],
          target_line,
          level,
          message,
          nil,
          self.class
        )
      end
    end

    def diff_threshold
      # TODO: some config for this?
      200
    end

    def check_large_schema_diff
      return unless diff_threshold

      if schema_patches.sum(&:additions) >= diff_threshold || schema_patches.sum(&:deletions) >= diff_threshold
        add_message_at_patch(schema_patches.first, "Large schema diff, pay attention")
      end

      if structure_patches.sum(&:additions) >= diff_threshold || structure_patches.sum(&:deletions) >= diff_threshold
        add_message_at_patch(structure_patches.first, "Large structure diff, pay attention")
      end
    end

    def check_migrations_mixed_with_code
      return unless migration_patches.any? && non_migration_related_patches.any?

      add_message_at_patch(migration_patches, "Do not mix migrations with other stuff", :fatal)
    end

    def check_migration_version_numbers
      return unless migration_patches.any?

      version_numbers = migration_patches.map { |patch| patch.delta.new_file[:path].sub(/^[^0-9]*([0-9]+).+/, '\1') }

      schema_file_name = 'db/schema.rb'
      if File.exist?(schema_file_name) && !gitignored?(schema_file_name)
        if schema_patches.none?
          add_message_at_patch(migration_patches, "Migration file detected, but no changes in schema.rb", :error)
        else
          match = File.read(schema_file_name).match(%r{ActiveRecord::Schema.define\(version:\s*(?<version>[0-9_]+)\s*\)})
          if match
            schema_migration_version = match[:version]
            schema_migration_version_clean = schema_migration_version.gsub(/[^0-9]/, '')
            version_numbers.select { |version| version > schema_migration_version_clean }.each do |wrong_version|
              add_message_at_patch(
                migration_patches.first { |patch| patch.delta.new_file[:path].include?(wrong_version) },
                "Migration version #{wrong_version} is above schema.rb version #{schema_migration_version}"
              )
            end
          else
            add_message_at_patch(migration_patches.first, "Cannot detect schema migration version", :warning)
          end
        end
      end

      structure_file_name = 'db/structure.sql'
      if File.exist?(structure_file_name) && !gitignored?(structure_file_name)
        migration_line_regex = /\A\s*\('(?<version>[0-9]{14})'\)/
        structure_file_lines = File.readlines(structure_file_name)
        versions_from_schema = structure_file_lines.select{|line| line =~ migration_line_regex }

        missing_from_structure = false
        version_numbers.select { |version| versions_from_schema.none? { |strct_ver| strct_ver.include?(version) } }
          .each do |wrong_version|
          missing_from_structure = true
          add_message_at_patch(
            migration_patches.first { |patch| patch.delta.new_file[:path].include?(wrong_version) },
            "Migration #{wrong_version} is missing from structure.sql", :error
          )
        end

        if structure_patches.none? && !missing_from_structure
          add_message_at_patch(migration_patches, "Migration file detected, but no changes in structure.sql")
        end

        structure_patches.each do |patch|
          patch.added_lines.each do |line|
            next unless line.content.match?(migration_line_regex)
            match = line.content.match(migration_line_regex)
            version = match[:version]
            next if version_numbers.include?(version) ||
              line.content.end_with?(',') && patch.deleted_lines.any? { |deleted| deleted.content.include?(version) }

            add_message_at_patch(patch, "Migration #{version} is not present in this changeset", :error, line: line)
          end
        end

        bad_semicolon = !versions_from_schema.last.end_with?("');\n")
        unsorted_migrations = versions_from_schema != versions_from_schema.sort

        if bad_semicolon || unsorted_migrations
          add_message_at_patch(
            structure_patches.first{ |patch| patch.lines.any?{ |line| line.content.match?(migration_line_regex) } },
            "Migration versions must be sorted and have correct syntax"
            )
        end

        if structure_patches.any? &&
          !(structure_file_lines.last(2) == ["\n", "\n"] && structure_file_lines[-3] != "\n") &&
          !structure_file_lines.last.match?(/\A\s*[^\s]+\s*\n/)
          add_message_at_patch(structure_patches.last,
            "structure.sql must end with a newline or 2 empty lines", line: :last)
        end
      end

    end

    def gitignored?(path)
      # TODO: get this from rugged (but it's not exposed to plugins) or make more compatible
      `git check-ignore #{path}` != ""
    rescue Errno::ENOENT # when git not present
      nil
    end

    def migration_patches
      # nb: there may be engines added to migrations_paths in config or database.yml
      # but cannot check for this without more knowledge into the particular app
      # rails uses Dir[*paths.flat_map { |path| "#{path}/**/[0-9]*_*.rb" }]
      @migration_patches ||= @patches.select do |patch|
        patch.delta.added? && patch.delta.new_file[:path] =~ %r{db/migrate/.*[0-9]+_\w+.rb}
      end
    end

    def non_migration_related_patches
      @patches.reject do |patch|
        path = patch.delta.new_file[:path]
        # lines = added_lines + deleted_lines, allow edits in comments
        path =~ %r{db/migrate/.*[0-9]+_\w+.rb} || path =~ %r{db/schema.rb} || path =~ %r{db/structure.sql} ||
          path.end_with?('.rb') && patch.lines.all? do |line|
            !(line.addition? || line.deletion?) ||
            (line.content =~ /\A\s*#/ || line.content =~ /\A\s*\z/)
          end
      end
    end

    def schema_patches
      @schema_patches = @patches.select { |patch| patch.delta.new_file[:path] =~ %r{db/schema.rb} }
    end

    def structure_patches
      @structure_patches = @patches.select { |patch| patch.delta.new_file[:path] =~ %r{db/structure.sql} }
    end

  end
end
