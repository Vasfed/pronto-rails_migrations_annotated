# frozen_string_literal: true

require 'fileutils'

RSpec.describe Pronto::RailsMigrationsAnnotated do
  it "has a version number" do
    expect(Pronto::RailsMigrationsAnnotated::VERSION).not_to be nil
  end

  let(:repo_folder) { File.expand_path('../fixtures/somerepo', __dir__) }
  let(:repo) do
    Pronto::Git::Repository.new(repo_folder).tap do |pronto_repo|
      raise "Proto::Repo already responds to :rugged" if pronto_repo.respond_to?(:rugged)

      def pronto_repo.rugged
        @repo
      end
    end
  end
  let(:base_branch) { 'master' }
  let(:test_branch) { 'master' }
  let(:patches) { repo.rugged.checkout(test_branch); repo.diff(base_branch) }

  subject(:warnings) { described_class.new(patches, nil).run }
  let(:warning_messages) { warnings.map(&:msg) }

  around do |example|
    # to be able to keep test repo inside other git repo - make `somerepo/.git` a regular directory and back
    git_dir = "#{repo_folder}/.git"
    inactive_git_dir = "#{repo_folder}/git"
    FileUtils.mv(inactive_git_dir, git_dir) unless File.directory?(git_dir)

    repo.rugged.checkout(test_branch)
    Dir.chdir(repo_folder) do
      example.run
    end
  ensure
    repo.rugged.checkout(base_branch) unless ENV['KEEP_GIT']
    FileUtils.mv(git_dir, inactive_git_dir) unless ENV['KEEP_GIT']
  end

  describe "Migration mixing detector" do
    let(:trigger) { include(/Do not mix migrations/) }

    context "when no migrations in PR" do
      let(:test_branch) { 'no_migrations' }
      it { expect(warning_messages).not_to trigger }
    end

    context "when migrations present" do
      let(:test_branch) { 'migrations' }
      it { expect(warning_messages).not_to trigger }

      context "but not changes to structure.sql" do
        let(:test_branch) { 'schema_changes_missing_version_structure' }
        it { expect(warning_messages).to include(/Migration 20211210200001 is missing from structure.sql/) }
        it { expect(warning_messages).to include(/Migration 20211210200000 is not present in this changeset/) }
      end

      context "but comments in some files" do
        let(:test_branch) { 'migrations_with_annotations' }
        it { expect(warning_messages).not_to trigger }
      end
    end

    context "when migrations and other code" do
      let(:test_branch) { 'code_with_migrations' }
      it { expect(warning_messages).to trigger }
    end
  end
end
