require File.expand_path('../../test_helper', __FILE__)
require 'issues_controller'

class IssuesControllerTest < ActionController::TestCase
  fixtures :projects,
           :users,
           :roles,
           :members,
           :member_roles,
           :issues,
           :issue_statuses,
           :versions,
           :trackers,
           :projects_trackers,
           :issue_categories,
           :enabled_modules,
           :enumerations

  include Redmine::I18n

  def setup
    @controller = IssuesController.new
    @request    = ActionController::TestRequest.new
    @response   = ActionController::TestResponse.new
    @user = User.find(2)
    @issue = Issue.find(1)
    @project = @issue.project
    User.current = @user
    @request.session[:user_id] = 2
    make_temp_dir
    @repository = create_test_repository(:project => @project)
    @repository.fetch_changesets
  end

  def teardown
    remove_temp_dir
  end

  def test_show_branches_in_associated_revisions
    changeset = @repository.changesets.last
    branches = Array.new(15) { |i| "fakebranch#{i}" }
    changeset.update_attribute :branches, branches
    @issue.changesets << changeset
    max_branches = Setting.plugin_redmine_undev_git[:max_branches_in_assoc].to_i

    get :show, :id => 1
    assert_response :success

    assert_select 'div#issue-changesets a', {:text => /fakebranch/} do |links|
      assert_equal max_branches, links.length
    end
  end
end
