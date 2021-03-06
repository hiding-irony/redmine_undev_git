require File.expand_path( '../../../test_helper', __FILE__ )

class UndevGitTest < ActiveSupport::TestCase
  fixtures :projects, :repositories, :enabled_modules, :users, :roles

  include Redmine::I18n

  NUM_REV = 28
  NUM_HEAD = 6

  FELIX_HEX  = "Felix Sch\xC3\xA4fer"
  CHAR_1_HEX = "\xc3\x9c"

  ## Git, Mercurial and CVS path encodings are binary.
  ## Subversion supports URL encoding for path.
  ## Redmine Mercurial adapter and extension use URL encoding.
  ## Git accepts only binary path in command line parameter.
  ## So, there is no way to use binary command line parameter in JRuby.
  JRUBY_SKIP     = (RUBY_PLATFORM == 'java')
  JRUBY_SKIP_STR = "TODO: This test fails in JRuby"

  def setup
    make_temp_dir
    Setting.enabled_scm << 'UndevGit'
    @project = Project.find(3)
    @repository = Repository::UndevGit.create(
        :project       => @project,
        :url           => REPOSITORY_PATH,
        :path_encoding => 'ISO-8859-1'
    )
    assert @repository
    @char_1        = CHAR_1_HEX.dup
    if @char_1.respond_to?(:force_encoding)
      @char_1.force_encoding('UTF-8')
    end
  end

  def teardown
    remove_temp_dir
  end

  def test_blank_path_to_repository_error_message
    set_language_if_valid 'en'
    repo = Repository::UndevGit.new(
        :project      => @project,
        :identifier   => 'test'
    )
    assert !repo.save
    assert_include "Path to repository can't be blank",
                   repo.errors.full_messages
  end

  def test_blank_path_to_repository_error_message_fr
    set_language_if_valid 'fr'
    str = "Chemin du d\xc3\xa9p\xc3\xb4t doit \xc3\xaatre renseign\xc3\xa9(e)"
    str.force_encoding('UTF-8') if str.respond_to?(:force_encoding)
    repo = Repository::UndevGit.new(
        :project      => @project,
        :url          => "",
        :identifier   => 'test',
        :path_encoding => ''
    )
    assert !repo.save
    assert_include str, repo.errors.full_messages
  end

  if File.directory?(REPOSITORY_PATH)
    ## Ruby uses ANSI api to fork a process on Windows.
    ## Japanese Shift_JIS and Traditional Chinese Big5 have 0x5c(backslash) problem
    ## and these are incompatible with ASCII.
    ## Git for Windows (msysGit) changed internal API from ANSI to Unicode in 1.7.10
    ## http://code.google.com/p/msysgit/issues/detail?id=80
    ## So, Latin-1 path tests fail on Japanese Windows
    WINDOWS_PASS = (Redmine::Platform.mswin? &&
        Redmine::Scm::Adapters::GitAdapter.client_version_above?([1, 7, 10]))
    WINDOWS_SKIP_STR = "TODO: This test fails in Git for Windows above 1.7.10"

    def test_scm_available
      klass = Repository::UndevGit
      assert_equal 'UndevGit', klass.scm_name
      assert klass.scm_adapter_class
      assert_not_equal '', klass.scm_command
      assert_equal true, klass.scm_available
    end

    def test_entries
      entries = @repository.entries
      assert_kind_of Redmine::Scm::Adapters::Entries, entries
    end

    def test_fetch_changesets_from_scratch
      assert_nil @repository.extra_info

      assert_equal 0, @repository.changesets.count
      @repository.fetch_changesets
      @project.reload

      assert_equal NUM_REV, @repository.changesets.count
      assert_equal 39, @repository.filechanges.count

      commit = @repository.changesets.find_by_revision("7234cb2750b63f47bff735edc50a1c0a433c2518")
      assert_equal "7234cb2750b63f47bff735edc50a1c0a433c2518", commit.scmid
      assert_equal "Initial import.\nThe repository contains 3 files.", commit.comments
      assert_equal "jsmith <jsmith@foo.bar>", commit.committer
      assert_equal User.find_by_login('jsmith'), commit.user
      # TODO: add a commit with commit time <> author time to the test repository
      assert_equal "2007-12-14 09:22:52".to_time, commit.committed_on
      assert_equal "2007-12-14".to_date, commit.commit_date
      assert_equal 3, commit.filechanges.count
      change = commit.filechanges.sort_by(&:path).first
      assert_equal "README", change.path
      assert_equal nil, change.from_path
      assert_equal "A", change.action

      assert_equal NUM_HEAD, @repository.extra_info["heads"].size
    end

    def test_fetch_changesets_incremental
      assert_equal 0, @repository.changesets.count
      @repository.fetch_changesets
      @project.reload
      assert_equal NUM_REV, @repository.changesets.count
      extra_info_heads = @repository.extra_info["heads"].dup
      assert_equal NUM_HEAD, extra_info_heads.size
      extra_info_heads.delete_if { |x| x == "83ca5fd546063a3c7dc2e568ba3355661a9e2b2c" }
      assert_equal 4, extra_info_heads.size

      del_revs = [
          "83ca5fd546063a3c7dc2e568ba3355661a9e2b2c",
          "ed5bb786bbda2dee66a2d50faf51429dbc043a7b",
          "4f26664364207fa8b1af9f8722647ab2d4ac5d43",
          "deff712f05a90d96edbd70facc47d944be5897e3",
          "32ae898b720c2f7eec2723d5bdd558b4cb2d3ddf",
          "7e61ac704deecde634b51e59daa8110435dcb3da",
      ]
      @repository.changesets.each do |rev|
        rev.destroy if del_revs.detect {|r| r == rev.scmid.to_s }
      end
      @project.reload
      cs1 = @repository.changesets
      assert_equal NUM_REV - 6, cs1.count
      extra_info_heads << "4a07fe31bffcf2888791f3e6cbc9c4545cefe3e8"
      h = {}
      h["heads"] = extra_info_heads
      @repository.merge_extra_info(h)
      @repository.save
      @project.reload
      assert @repository.extra_info["heads"].index("4a07fe31bffcf2888791f3e6cbc9c4545cefe3e8")
      @repository.fetch_changesets
      @project.reload
      assert_equal NUM_REV, @repository.changesets.count
      assert_equal NUM_HEAD, @repository.extra_info["heads"].size
      assert @repository.extra_info["heads"].index("83ca5fd546063a3c7dc2e568ba3355661a9e2b2c")
    end

    def test_keep_extra_report_last_commit_in_clear_changesets
      assert_nil @repository.extra_info
      h = {}
      h["extra_report_last_commit"] = "1"
      @repository.merge_extra_info(h)
      @repository.save
      @project.reload

      assert_equal 0, @repository.changesets.count
      @repository.fetch_changesets
      @project.reload

      assert_equal NUM_REV, @repository.changesets.count
      @repository.send(:clear_changesets)
      assert_equal 1, @repository.extra_info.size
      assert_equal "1", @repository.extra_info["extra_report_last_commit"]
    end

    def test_refetch_after_clear_changesets
      assert_nil @repository.extra_info
      assert_equal 0, @repository.changesets.count
      @repository.fetch_changesets
      @project.reload
      assert_equal NUM_REV, @repository.changesets.count

      @repository.send(:clear_changesets)
      @project.reload
      assert_equal 0, @repository.changesets.count

      @repository.fetch_changesets
      @project.reload
      assert_equal NUM_REV, @repository.changesets.count
    end

    def test_parents
      assert_equal 0, @repository.changesets.count
      @repository.fetch_changesets
      @project.reload
      assert_equal NUM_REV, @repository.changesets.count
      r1 = @repository.find_changeset_by_name("7234cb2750b63")
      assert_equal [], r1.parents
      r2 = @repository.find_changeset_by_name("899a15dba03a3")
      assert_equal 1, r2.parents.length
      assert_equal "7234cb2750b63f47bff735edc50a1c0a433c2518",
                   r2.parents[0].identifier
      r3 = @repository.find_changeset_by_name("32ae898b720c2")
      assert_equal 2, r3.parents.length
      r4 = [r3.parents[0].identifier, r3.parents[1].identifier].sort
      assert_equal "4a07fe31bffcf2888791f3e6cbc9c4545cefe3e8", r4[0]
      assert_equal "7e61ac704deecde634b51e59daa8110435dcb3da", r4[1]
    end

    def test_db_consistent_ordering_before_1_2
      assert_nil @repository.extra_info
      assert_equal 0, @repository.changesets.count
      @repository.fetch_changesets
      @project.reload
      assert_equal NUM_REV, @repository.changesets.count
      assert_not_nil @repository.extra_info
      h = {}
      h["heads"] = []
      h["branches"] = {}
      @repository.merge_extra_info(h)
      @repository.save
      assert_equal NUM_REV, @repository.changesets.count
      @repository.fetch_changesets
      @project.reload

      extra_info_heads = @repository.extra_info["heads"].dup
      extra_info_heads.delete_if { |x| x == "83ca5fd546063a3c7dc2e568ba3355661a9e2b2c" }
      del_revs = [
          "83ca5fd546063a3c7dc2e568ba3355661a9e2b2c",
          "ed5bb786bbda2dee66a2d50faf51429dbc043a7b",
          "4f26664364207fa8b1af9f8722647ab2d4ac5d43",
          "deff712f05a90d96edbd70facc47d944be5897e3",
          "32ae898b720c2f7eec2723d5bdd558b4cb2d3ddf",
          "7e61ac704deecde634b51e59daa8110435dcb3da",
      ]
      @repository.changesets.each do |rev|
        rev.destroy if del_revs.detect {|r| r == rev.scmid.to_s }
      end
      @project.reload
      cs1 = @repository.changesets
      assert_equal NUM_REV - 6, cs1.count

      extra_info_heads << "4a07fe31bffcf2888791f3e6cbc9c4545cefe3e8"
      h = {}
      h["heads"] = extra_info_heads
      @repository.merge_extra_info(h)
      @repository.save
      @project.reload
      assert @repository.extra_info["heads"].index("4a07fe31bffcf2888791f3e6cbc9c4545cefe3e8")
      @repository.fetch_changesets
      @project.reload
      assert_equal NUM_REV, @repository.changesets.count
      assert_equal NUM_HEAD, @repository.extra_info["heads"].size
    end

    def test_latest_changesets
      assert_equal 0, @repository.changesets.count
      @repository.fetch_changesets
      @project.reload
      assert_equal NUM_REV, @repository.changesets.count
      # with limit
      changesets = @repository.latest_changesets('', 'master', 2)
      assert_equal 2, changesets.size

      # with path
      changesets = @repository.latest_changesets('images', 'master')
      assert_equal [
                       'deff712f05a90d96edbd70facc47d944be5897e3',
                       '899a15dba03a3b350b89c3f537e4bbe02a03cdc9',
                       '7234cb2750b63f47bff735edc50a1c0a433c2518',
                   ], changesets.collect(&:revision)

      changesets = @repository.latest_changesets('README', nil)
      assert_equal [
                       '32ae898b720c2f7eec2723d5bdd558b4cb2d3ddf',
                       '4a07fe31bffcf2888791f3e6cbc9c4545cefe3e8',
                       '713f4944648826f558cf548222f813dabe7cbb04',
                       '61b685fbe55ab05b5ac68402d5720c1a6ac973d1',
                       '899a15dba03a3b350b89c3f537e4bbe02a03cdc9',
                       '7234cb2750b63f47bff735edc50a1c0a433c2518',
                   ], changesets.collect(&:revision)

      # with path, revision and limit
      changesets = @repository.latest_changesets('images', '899a15dba')
      assert_equal [
                       '899a15dba03a3b350b89c3f537e4bbe02a03cdc9',
                       '7234cb2750b63f47bff735edc50a1c0a433c2518',
                   ], changesets.collect(&:revision)

      changesets = @repository.latest_changesets('images', '899a15dba', 1)
      assert_equal [
                       '899a15dba03a3b350b89c3f537e4bbe02a03cdc9',
                   ], changesets.collect(&:revision)

      changesets = @repository.latest_changesets('README', '899a15dba')
      assert_equal [
                       '899a15dba03a3b350b89c3f537e4bbe02a03cdc9',
                       '7234cb2750b63f47bff735edc50a1c0a433c2518',
                   ], changesets.collect(&:revision)

      changesets = @repository.latest_changesets('README', '899a15dba', 1)
      assert_equal [
                       '899a15dba03a3b350b89c3f537e4bbe02a03cdc9',
                   ], changesets.collect(&:revision)

      # with path, tag and limit
      changesets = @repository.latest_changesets('images', 'tag01.annotated')
      assert_equal [
                       '899a15dba03a3b350b89c3f537e4bbe02a03cdc9',
                       '7234cb2750b63f47bff735edc50a1c0a433c2518',
                   ], changesets.collect(&:revision)

      changesets = @repository.latest_changesets('images', 'tag01.annotated', 1)
      assert_equal [
                       '899a15dba03a3b350b89c3f537e4bbe02a03cdc9',
                   ], changesets.collect(&:revision)

      changesets = @repository.latest_changesets('README', 'tag01.annotated')
      assert_equal [
                       '899a15dba03a3b350b89c3f537e4bbe02a03cdc9',
                       '7234cb2750b63f47bff735edc50a1c0a433c2518',
                   ], changesets.collect(&:revision)

      changesets = @repository.latest_changesets('README', 'tag01.annotated', 1)
      assert_equal [
                       '899a15dba03a3b350b89c3f537e4bbe02a03cdc9',
                   ], changesets.collect(&:revision)

      # with path, branch and limit
      changesets = @repository.latest_changesets('images', 'test_branch')
      assert_equal [
                       '899a15dba03a3b350b89c3f537e4bbe02a03cdc9',
                       '7234cb2750b63f47bff735edc50a1c0a433c2518',
                   ], changesets.collect(&:revision)

      changesets = @repository.latest_changesets('images', 'test_branch', 1)
      assert_equal [
                       '899a15dba03a3b350b89c3f537e4bbe02a03cdc9',
                   ], changesets.collect(&:revision)

      changesets = @repository.latest_changesets('README', 'test_branch')
      assert_equal [
                       '713f4944648826f558cf548222f813dabe7cbb04',
                       '61b685fbe55ab05b5ac68402d5720c1a6ac973d1',
                       '899a15dba03a3b350b89c3f537e4bbe02a03cdc9',
                       '7234cb2750b63f47bff735edc50a1c0a433c2518',
                   ], changesets.collect(&:revision)

      changesets = @repository.latest_changesets('README', 'test_branch', 2)
      assert_equal [
                       '713f4944648826f558cf548222f813dabe7cbb04',
                       '61b685fbe55ab05b5ac68402d5720c1a6ac973d1',
                   ], changesets.collect(&:revision)

      if WINDOWS_PASS
        puts WINDOWS_SKIP_STR
      elsif JRUBY_SKIP
        puts JRUBY_SKIP_STR
      else
        # latin-1 encoding path
        changesets = @repository.latest_changesets(
            "latin-1-dir/test-#{@char_1}-2.txt", '64f1f3e89')
        assert_equal [
                         '64f1f3e89ad1cb57976ff0ad99a107012ba3481d',
                         '4fc55c43bf3d3dc2efb66145365ddc17639ce81e',
                     ], changesets.collect(&:revision)

        changesets = @repository.latest_changesets(
            "latin-1-dir/test-#{@char_1}-2.txt", '64f1f3e89', 1)
        assert_equal [
                         '64f1f3e89ad1cb57976ff0ad99a107012ba3481d',
                     ], changesets.collect(&:revision)
      end
    end

    def test_latest_changesets_latin_1_dir
      if WINDOWS_PASS
        puts WINDOWS_SKIP_STR
      elsif JRUBY_SKIP
        puts JRUBY_SKIP_STR
      else
        assert_equal 0, @repository.changesets.count
        @repository.fetch_changesets
        @project.reload
        assert_equal NUM_REV, @repository.changesets.count
        changesets = @repository.latest_changesets(
            "latin-1-dir/test-#{@char_1}-subdir", '1ca7f5ed')
        assert_equal [
                         '1ca7f5ed374f3cb31a93ae5215c2e25cc6ec5127',
                     ], changesets.collect(&:revision)
      end
    end

    def test_find_changeset_by_name
      assert_equal 0, @repository.changesets.count
      @repository.fetch_changesets
      @project.reload
      assert_equal NUM_REV, @repository.changesets.count
      ['7234cb2750b63f47bff735edc50a1c0a433c2518', '7234cb2750b'].each do |r|
        assert_equal '7234cb2750b63f47bff735edc50a1c0a433c2518',
                     @repository.find_changeset_by_name(r).revision
      end
    end

    def test_find_changeset_by_empty_name
      assert_equal 0, @repository.changesets.count
      @repository.fetch_changesets
      @project.reload
      assert_equal NUM_REV, @repository.changesets.count
      ['', ' ', nil].each do |r|
        assert_nil @repository.find_changeset_by_name(r)
      end
    end

    def test_identifier
      assert_equal 0, @repository.changesets.count
      @repository.fetch_changesets
      @project.reload
      assert_equal NUM_REV, @repository.changesets.count
      c = @repository.changesets.find_by_revision(
          '7234cb2750b63f47bff735edc50a1c0a433c2518')
      assert_equal c.scmid, c.identifier
    end

    def test_format_identifier
      assert_equal 0, @repository.changesets.count
      @repository.fetch_changesets
      @project.reload
      assert_equal NUM_REV, @repository.changesets.count
      c = @repository.changesets.find_by_revision(
          '7234cb2750b63f47bff735edc50a1c0a433c2518')
      assert_equal '7234cb27', c.format_identifier
    end

    def test_activities
      c = Changeset.new(:repository => @repository,
                        :committed_on => Time.now,
                        :revision => 'abc7234cb2750b63f47bff735edc50a1c0a433c2',
                        :scmid    => 'abc7234cb2750b63f47bff735edc50a1c0a433c2',
                        :comments => 'test')
      assert c.event_title.include?('abc7234c:')
      assert_equal 'abc7234cb2750b63f47bff735edc50a1c0a433c2', c.event_url[:rev]
    end

    def test_log_utf8
      assert_equal 0, @repository.changesets.count
      @repository.fetch_changesets
      @project.reload
      assert_equal NUM_REV, @repository.changesets.count
      str_felix_hex  = FELIX_HEX.dup
      if str_felix_hex.respond_to?(:force_encoding)
        str_felix_hex.force_encoding('UTF-8')
      end
      c = @repository.changesets.find_by_revision(
          'ed5bb786bbda2dee66a2d50faf51429dbc043a7b')
      assert_equal "#{str_felix_hex} <felix@fachschaften.org>", c.committer
    end

    def test_previous
      assert_equal 0, @repository.changesets.count
      @repository.fetch_changesets
      @project.reload
      assert_equal NUM_REV, @repository.changesets.count
      %w|1ca7f5ed374f3cb31a93ae5215c2e25cc6ec5127 1ca7f5ed|.each do |r1|
        changeset = @repository.find_changeset_by_name(r1)
        %w|64f1f3e89ad1cb57976ff0ad99a107012ba3481d 64f1f3e89ad1|.each do |r2|
          assert_equal @repository.find_changeset_by_name(r2), changeset.previous
        end
      end
    end

    def test_previous_nil
      assert_equal 0, @repository.changesets.count
      @repository.fetch_changesets
      @project.reload
      assert_equal NUM_REV, @repository.changesets.count
      %w|7234cb2750b63f47bff735edc50a1c0a433c2518 7234cb275|.each do |r1|
        changeset = @repository.find_changeset_by_name(r1)
        assert_nil changeset.previous
      end
    end

    def test_next
      assert_equal 0, @repository.changesets.count
      @repository.fetch_changesets
      @project.reload
      assert_equal NUM_REV, @repository.changesets.count
      %w|64f1f3e89ad1cb57976ff0ad99a107012ba3481d 64f1f3e89ad1|.each do |r2|
        changeset = @repository.find_changeset_by_name(r2)
        %w|1ca7f5ed374f3cb31a93ae5215c2e25cc6ec5127 1ca7f5ed|.each do |r1|
          assert_equal @repository.find_changeset_by_name(r1), changeset.next
        end
      end
    end

    def test_next_nil
      assert_equal 0, @repository.changesets.count
      @repository.fetch_changesets
      @project.reload
      assert_equal NUM_REV, @repository.changesets.count
      %w|2a682156a3b6e77a8bf9cd4590e8db757f3c6c78 2a682156a3b6e77a|.each do |r1|
        changeset = @repository.find_changeset_by_name(r1)
        assert_nil changeset.next
      end
    end

    def test_repository_urls
      good_urls = %w{
        git://host.xz/path/to/repo.git/
        git://host.xz/path/to/repo.git
        git://host.xz:port/path/to/repo.git/
        git://host.xz:port/path/to/repo.git

        http://host.xz/path/to/repo.git/
        http://host.xz/path/to/repo.git
        http://host.xz:port/path/to/repo.git/
        http://host.xz:port/path/to/repo.git

        https://host.xz/path/to/repo.git/
        https://host.xz/path/to/repo.git
        https://host.xz:port/path/to/repo.git/
        https://host.xz:port/path/to/repo.git
      }

      bad_urls = [
        'ssh://user@host. xz/path/to/repo.git/',
        'ssh://user@host.xz:port/pa th/to/repo.git/',
        'ssh:// user@host.xz:port/path/to/repo.git',
        'ttp://host.xz:port/path/to/repo.git',

        'ftp://host.xz/path/to/repo.git/',
        'ftp://host.xz/path/to/repo.git',
        'ftp://host.xz:port/path/to/repo.git/',
        'ftp://host.xz:port/path/to/repo.git',

        'ftp://host.xz/path/to/repo.git/',
        'ftp://host.xz/path/to/repo.git',
        'ftps://host.xz:port/path/to/repo.git/',
        'ftps://host.xz:port/path/to/repo.git',

        'user@host.xz:path/to/repo.git/',
        'user@host.xz:path/to/repo.git',

        'ssh://user@host.xz/path/to/repo.git/',
        'ssh://user@host.xz/path/to/repo.git',
        'ssh://user@host.xz:port/path/to/repo.git/',
        'ssh://user@host.xz:port/path/to/repo.git'

      ]

      good_urls.each do |good_url|
        repo = Repository::UndevGit.new(
            :project => @project,
            :identifier => 'test_url',
            :is_default => false,
            :url => good_url
        )
        assert_true repo.valid?, "#{good_url} should be valid"
      end

      bad_urls.each do |bad_url|
        repo = Repository::UndevGit.new(
            :project => @project,
            :identifier => 'test_url',
            :is_default => false,
            :url => bad_url
        )
        assert_false repo.valid?, "#{bad_url} should not be valid"
      end
    end

    def test_branches_in_associated_revisions
      #TODO
    end

    def test_rebased_from
      cs = rebased_changesets

      assert_equal cs[:c3], cs[:c3r].rebased_from
      assert_equal cs[:c4], cs[:c4r].rebased_from
      assert_equal cs[:c8], cs[:c8r].rebased_from
      assert_equal cs[:c9], cs[:c9r].rebased_from
      assert_equal cs[:c10], cs[:c10r].rebased_from
    end

    def test_rebased_to
      cs = rebased_changesets

      assert_equal cs[:c3r], cs[:c3].rebased_to
      assert_equal cs[:c4r], cs[:c4].rebased_to
      assert_equal cs[:c8r], cs[:c8].rebased_to
      assert_equal cs[:c9r], cs[:c9].rebased_to
      assert_equal cs[:c10r], cs[:c10].rebased_to
    end

    def test_change_issue_by_project_hook
      repository = create_test_repository(:use_init_hooks => '1', :identifier => 'x')
      repository.fetch_changesets
      create_hooks!(:repository_id => repository.id)
      changeset = repository.changesets.last
      changeset.comments = 'fix #5'
      issue = Issue.find(5)
      assert_equal 0, issue.done_ratio
      repository.send :initial_parse_comments, changeset
      repository.send :apply_hooks_for_branch, changeset, 'master'
      issue.reload
      assert_equal 70, issue.done_ratio
    end

    def test_change_issue_by_global_hook
      repository = create_test_repository(:use_init_hooks => '1', :identifier => 'x')
      repository.fetch_changesets
      create_hooks!(:repository_id => repository.id)
      changeset = repository.changesets.last
      changeset.comments = 'closes #5'
      changeset.branches << 'production'
      issue = Issue.find(5)
      assert_equal 0, issue.done_ratio
      repository.send :initial_parse_comments, changeset
      repository.send :apply_hooks_for_branch, changeset, 'production'
      issue.reload
      assert_equal 80, issue.done_ratio
    end

    def test_remove_repository_folder
      repository = create_test_repository(:identifier => 'x')
      repository.fetch_changesets
      root_url = repository.root_url
      assert_true Dir.exists?(root_url)
      repository.destroy
      assert_false Dir.exists?(root_url)
    end

    def test_previous_branches
      repository = create_test_repository(:identifier => 'x')
      repository.fetch_changesets
      exp_branches = {}
      repository.branches.each do |branch|
        exp_branches[branch.to_s] = branch.scmid
      end
      branches = repository.send :previous_branches
      assert_equal exp_branches.sort, branches.sort
    end

  else
    puts 'Git test repository NOT FOUND. Skipping unit tests !!!'
    def test_fake; assert true end
  end

end
