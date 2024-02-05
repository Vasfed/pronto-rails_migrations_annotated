# frozen_string_literal: true

require "pronto"
require_relative "rails_migrations_annotated/version"

module Pronto
  # Runner that detects migration smells
  class RailsMigrationsAnnotated < Runner
    VERSION = Pronto::RailsMigrationsAnnotatedVersion::VERSION

    def run
      @messages = []

      check_migrations_mixed_with_code
      check_migration_schema_version
      check_structure_migration_version_numbers
      check_large_schema_diff
      check_large_structure_diff

      @messages
    end

    # TODO: override def self.title ?

    private

    def add_message_at_patch(patches, message, level = :warning, line: :first)
      patches = [patches].compact unless patches.is_a?(Array)
      raise "Patch not found for message (#{message.inspect})" if patches.empty?

      patches.each do |patch|
        target_line = case line
                      when :first then patch.added_lines.first || patch.lines.first
                      when :last then patch.added_lines.last || patch.lines.last
                      else line
                      end
        @messages << Message.new(patch.delta.new_file[:path], target_line, level, message, nil, self.class)
      end
    end

    def diff_threshold
      # TODO: some config for this?
      200
    end

    def check_large_schema_diff
      return unless diff_threshold
      return unless schema_patches.sum(&:additions) >= diff_threshold ||
                    schema_patches.sum(&:deletions) >= diff_threshold

      add_message_at_patch(schema_patches.first, "Large schema diff, pay attention")
    end

    def check_large_structure_diff
      return unless diff_threshold
      return unless structure_patches.sum(&:additions) >= diff_threshold ||
                    structure_patches.sum(&:deletions) >= diff_threshold

      add_message_at_patch(structure_patches.first, "Large structure diff, pay attention")
    end

    def check_migrations_mixed_with_code
      return unless migration_patches.any? && non_migration_related_patches.any?

      add_message_at_patch(migration_patches, "Do not mix migrations with other stuff", :fatal)
    end

    def check_migration_schema_version
      return if migration_patches.none? || !File.exist?(schema_file_name) || gitignored?(schema_file_name)

      if schema_patches.none?
        return add_message_at_patch(migration_patches, "Migration file detected, but no changes in schema.rb", :error)
      end

      migration_version_numbers.select { |version| schema_migration_version&.<(version) }.each do |wrong_version|
        add_message_at_patch(
          migration_patches.first { |patch| patch.delta.new_file[:path].include?(wrong_version) },
          "Migration version #{wrong_version} is above schema.rb version #{schema_migration_version}"
        )
      end
    end

    def schema_migration_version
      return @schema_migration_version if defined? @schema_migration_version

      @schema_migration_version ||= File.read(schema_file_name)
                                        .match(/ActiveRecord::Schema.define\(version:\s*(?<version>[0-9_]+)\s*\)/)
                                        &.[](:version)&.gsub(/[^0-9]/, "") ||
                                    (add_message_at_patch(migration_patches.first,
                                                          "Cannot detect migration version in schema.rb. "\
                                                          "Migration versions are not checked.",
                                                          :warning) && nil)
    end

    def migration_version_numbers
      @migration_version_numbers ||= migration_patches.map do |patch|
        patch.delta.new_file[:path].sub(/^[^0-9]*([0-9]+).+/, '\1')
      end
    end

    def check_structure_migration_version_numbers
      # return unless migration_patches.any?

      structure_file_name = "db/structure.sql"
      return if !File.exist?(structure_file_name) || gitignored?(structure_file_name)

      structure_file_lines = File.readlines(structure_file_name)
      versions_from_schema = structure_file_lines.grep(migration_line_regex)

      check_structure_versions_present(versions_from_schema)
      check_structure_migration_missing

      check_structure_versions_syntax(versions_from_schema) if versions_from_schema.any?
      check_structure_versions_sorted(versions_from_schema)
      check_structure_ending(structure_file_lines)
    end

    def check_structure_versions_present(versions_from_schema)
      found_missing_migration = false
      migration_version_numbers.select { |version| versions_from_schema.none? { |ver| ver.include?(version) } }
                               .each do |wrong_version|
        found_missing_migration = true
        add_message_at_patch(migration_patches.first { |patch| patch.delta.new_file[:path].include?(wrong_version) },
                             "Migration #{wrong_version} is missing from structure.sql", :error)
      end

      return if structure_patches.any? || found_missing_migration || migration_patches.none?

      add_message_at_patch(migration_patches, "Migration file detected, but no changes in structure.sql")
    end

    def check_structure_migration_missing
      structure_patches.each do |patch|
        next if patch.delta.old_file[:oid] == "0000000000000000000000000000000000000000" # new structure.sql file

        triggered = false
        patch.added_lines.select { |line| line.content.match?(migration_line_regex) }.each do |line|
          version = line.content.match(migration_line_regex)[:version]
          next if migration_version_numbers.include?(version)
          next if line.content.end_with?(",\n") &&
                  patch.deleted_lines.any? { |del| del.content.include?("#{version}');") }

          triggered = true
          add_message_at_patch(patch, "Migration #{version} is not present in this changeset", :error, line: line)
        end

        if !triggered && migration_version_numbers.none?
          add_message_at_patch(patch, "structure.sql changed without migrations", :error, line: patch.lines.first)
        end
      end
    end

    def check_structure_versions_sorted(versions_from_schema)
      return if versions_from_schema == versions_from_schema.sort
      return if versions_from_schema == versions_from_schema.sort.reverse

      # guess sort order by lower offending migrations count
      offending = [
        versions_from_schema.each_cons(2).select { |(a, b)| a > b }, # if ascending
        versions_from_schema.each_cons(2).select { |(a, b)| a < b } # if sort is desc
      ].min_by(&:size).flat_map { |pair| pair.map { |line| line.gsub(/[^0-9]+/, "") } }

      if structure_patches.none?
        puts "WARNING: structure.sql migrations are not sorted (not in changes, offending #{offending.join(', ')})"
        return
      end

      offending_regex = Regexp.union(offending)

      add_message_at_patch(
        structure_patches.first { |patch| patch.lines.any? { |line| line.content.match?(offending_regex) } } ||
        structure_patches.first { |patch| patch.lines.any? { |line| line.content.match?(migration_line_regex) } },
        "Migration versions must be sorted and have correct syntax"
      )
    end

    def check_structure_versions_syntax(versions_from_schema)
      return if versions_from_schema.last.end_with?("');\n") &&
                versions_from_schema.all? { |line| line.end_with?("'),\n", "');\n") }

      add_message_at_patch(
        structure_patches.first { |patch| patch.lines.any? { |line| line.content.match?(migration_line_regex) } },
        "Migration version lines must be separated by comma and end with semicolon"
      )
    end

    def check_structure_ending(structure_file_lines)
      return if structure_patches.none?
      return if structure_file_lines.last(2) == %W[\n \n] && structure_file_lines[-3] != "\n"
      return if structure_file_lines.last.match?(/\A\s*[^\s]+\s*\n/)

      add_message_at_patch(structure_patches.last,
                           "structure.sql must end with a newline or 2 empty lines", line: :last)
    end

    def gitignored?(path)
      # TODO: get this from rugged (but it's not exposed to plugins) or make more compatible
      `git check-ignore #{path}` != ""
    rescue Errno::ENOENT # when git not present
      nil
    end

    def schema_file_name
      "db/schema.rb"
    end

    def migration_line_regex
      /\A\s*\('(?<version>[0-9]{14})'\)/
    end

    def migration_related_files
      Regexp.union(
        %r{db/migrate/.*[0-9]+_\w+.rb},
        %r{db/schema.rb},
        %r{db/structure.sql}
      )
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
      @patches.select do |patch|
        path = patch.delta.new_file[:path]
        next false if path.match?(migration_related_files)

        # allow edits in comments and blank lines (model annotations usually come there)
        !path.end_with?(".rb") || patch.lines.any? do |line|
          (line.addition? || line.deletion?) && !line.content.match?(/\A\s*(#|\z)/)
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
