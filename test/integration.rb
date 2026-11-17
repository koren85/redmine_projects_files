# Run on a disposable Redmine/PostgreSQL database with default data loaded:
# RAILS_ENV=production bundle exec rails runner plugins/redmine_projects_files/test/integration.rb
require 'minitest/autorun'
require 'action_dispatch/testing/integration'
require 'stringio'
require 'nokogiri'
ActionMailer::Base.perform_deliveries = false
Rails.logger.level = Logger::ERROR

class ProjectFilesIntegrationTest < Minitest::Test
  def setup
    ActiveRecord::Base.connection.begin_transaction(:joinable => false)
    @role = Role.create!(:name => 'Catalogue reader', :permissions => [:view_project, :view_issues, :download_project_files], :issues_visibility => 'default')
    @author_role = Role.create!(:name => 'Uploader', :permissions => [:view_project, :view_issues])
    @user = user('reader')
    @author = user('uploader')
    @stranger = user('stranger')
    @project = project('catalogue')
    @other = project('other')
    Member.create!(:project => @project, :principal => @user, :roles => [@role])
    Member.create!(:project => @project, :principal => @author, :roles => [@author_role])
    Member.create!(:project => @other, :principal => @author, :roles => [@role])
    @group = Group.create!(:lastname => 'Upload team')
    @group.users << @author
    @issue = issue(@project)
    @private_issue = issue(@project, true)
    @file = attachment(@issue, 'пример.txt', 'public content')
    @private_file = attachment(@private_issue, 'secret.txt', 'secret content')
    @other_file = attachment(issue(@other), 'other.txt', 'other content')
    @session = ActionDispatch::Integration::Session.new(Rails.application)
    @session.host! 'localhost'
    login(@user)
  end

  def teardown
    Array(@created_files).each { |path| File.delete(path) if File.exist?(path) }
    ActiveRecord::Base.connection.rollback_transaction
    User.current = nil
  end

  def user(login)
    User.create!(:login => "pf_#{login}", :firstname => login, :lastname => 'Test', :mail => "pf_#{login}@example.test", :password => 'Test-password-123', :password_confirmation => 'Test-password-123')
  end

  def project(identifier)
    Project.create!(:name => identifier, :identifier => "pf-#{identifier}", :is_public => false,
      :enabled_module_names => %w(issue_tracking files documents wiki news boards project_files), :trackers => [Tracker.first])
  end

  def issue(project, private_issue = false)
    Issue.create!(:project => project, :tracker => Tracker.first, :status => IssueStatus.first,
      :priority => IssuePriority.first, :author => @author, :subject => 'Catalogue test issue', :is_private => private_issue)
  end

  def attachment(container, name, content)
    file = StringIO.new(content)
    file.define_singleton_method(:original_filename) { name }
    file.define_singleton_method(:content_type) { 'text/plain' }
    a = Attachment.create!(:container => container, :author => @author, :file => file)
    (@created_files ||= []) << a.diskfile
    a
  end

  def token
    Nokogiri::HTML(@session.response.body).at_css('input[name="authenticity_token"]')['value']
  end

  def login(user)
    @session.get('/login')
    @session.post('/login', :params => {:username => user.login, :password => 'Test-password-123', :authenticity_token => token})
    assert_equal 302, @session.response.status
  end

  def archive(params)
    @session.get('/project_files')
    @session.post('/project_files/archive', :params => params.merge(:authenticity_token => token))
  end

  def test_visibility_and_single_download
    @session.get('/project_files')
    assert_equal 200, @session.response.status
    assert_includes @session.response.body, 'пример.txt'
    refute_includes @session.response.body, 'secret.txt'
    refute_includes @session.response.body, 'other.txt'
    @session.get("/project_files/#{@file.id}/download")
    assert_equal 200, @session.response.status
    assert_equal 'public content', @session.response.body
    [@private_file, @other_file].each do |a|
      @session.get("/project_files/#{a.id}/download")
      assert_equal 404, @session.response.status
    end
  end

  def test_explicit_full_permission_and_disabled_module
    @role.add_permission! :download_all_project_files
    @session.get('/project_files')
    assert_includes @session.response.body, 'secret.txt'
    @session.get("/project_files/#{@private_file.id}/download")
    assert_equal 'secret content', @session.response.body
    @project.enabled_modules.where(:name => 'project_files').delete_all
    @session.get('/project_files')
    assert_equal 403, @session.response.status
  end

  def test_filters_project_issue_author_group_and_project_specific_role
    filters = [{:project_id => @project.id}, {:project_id => @project.identifier}, {:issue_id => @issue.id},
      {:author_id => @author.id}, {:group_id => @group.id}, {:role_id => @author_role.id}]
    filters.each do |filter|
      @session.get('/project_files', :params => filter)
      assert_equal 200, @session.response.status, filter.inspect
      assert_includes @session.response.body, 'пример.txt', filter.inspect
    end
    [{:issue_id => @private_issue.id}, {:author_id => @stranger.id}, {:role_id => @role.id}].each do |filter|
      @session.get('/project_files', :params => filter)
      refute_includes @session.response.body, 'пример.txt', filter.inspect
    end
    @session.get('/project_files', :params => {:project_id => @other.id})
    assert_equal 403, @session.response.status
  end

  def test_zip_content_and_forbidden_id_rejection
    archive(:attachment_ids => [@file.id])
    assert_equal 200, @session.response.status
    assert_equal 'application/zip', @session.response.media_type
    Zip::InputStream.open(StringIO.new(@session.response.body)) do |zip|
      entry = zip.get_next_entry
      assert_equal "#{@project.id}/#{@file.id}_пример.txt", entry.name.dup.force_encoding('UTF-8')
      assert_equal Zip::Entry::EFS, entry.gp_flags & Zip::Entry::EFS
      assert_equal 'public content', zip.read
      assert_nil zip.get_next_entry
    end
    archive(:attachment_ids => [@file.id, @other_file.id])
    assert_equal 404, @session.response.status
    archive(:attachment_ids => [@file.id, @private_file.id])
    assert_equal 404, @session.response.status
    archive(:attachment_ids => [999999999])
    assert_equal 404, @session.response.status
    archive(:attachment_ids => ['../etc/passwd'])
    assert_equal 404, @session.response.status
  end

  def test_archive_limits_empty_and_all_filtered
    archive(:attachment_ids => [])
    assert_equal 422, @session.response.status
    archive(:attachment_ids => [@file.id] * 501)
    assert_equal 422, @session.response.status
    @file.update_column(:filesize, ProjectFilesController::MAX_BYTES + 1)
    archive(:attachment_ids => [@file.id])
    assert_equal 422, @session.response.status
    @file.update_column(:filesize, 14)
    archive(:all_filtered => '1', :issue_id => @issue.id)
    assert_equal 200, @session.response.status
    Zip::InputStream.open(StringIO.new(@session.response.body)) do |zip|
      assert zip.get_next_entry
      assert_equal 'public content', zip.read
      assert_nil zip.get_next_entry
    end
  end

  def test_permission_revocation_and_no_permission
    @role.remove_permission! :download_project_files
    @session.get('/project_files')
    assert_equal 403, @session.response.status
    @session.get("/project_files/#{@file.id}/download")
    assert_equal 403, @session.response.status
  end

  def test_other_containers_and_unattached_files
    @role.add_permission! :download_all_project_files
    version = Version.create!(:project => @project, :name => 'v1')
    doc = Document.create!(:project => @project, :title => 'Doc', :category => DocumentCategory.first)
    wiki = Wiki.create!(:project => @project, :start_page => 'Start')
    page = WikiPage.create!(:wiki => wiki, :title => 'Start')
    news = News.create!(:project => @project, :title => 'News', :description => 'News body', :author => @author)
    board = Board.create!(:project => @project, :name => 'Board', :description => 'Board')
    message = Message.create!(:board => board, :subject => 'Message', :content => 'Message body', :author => @author)
    files = [@project, version, doc, page, news, message].map { |c| attachment(c, "#{c.class.name}.txt", c.class.name) }
    orphan = attachment(nil, 'unattached.txt', 'unattached')
    @session.get('/project_files')
    assert_equal 200, @session.response.status
    files.each { |f| assert_includes @session.response.body, f.filename }
    refute_includes @session.response.body, orphan.filename
  end

  def test_core_project_issue_and_attachment_routes_still_work
    @session.get("/projects/#{@project.identifier}")
    assert_equal 200, @session.response.status
    @session.get("/issues/#{@issue.id}")
    assert_equal 200, @session.response.status
    @session.get("/attachments/download/#{@file.id}")
    assert_equal 200, @session.response.status
    assert_equal 'public content', @session.response.body
  end
  def test_missing_diskfile_and_archive_cleanup
    before = Dir[File.join(Dir.tmpdir, 'project-files-*.zip')]
    archive(:attachment_ids => [@file.id])
    assert_equal 200, @session.response.status
    assert @session.response.body.start_with?("PK")
    assert_equal before, Dir[File.join(Dir.tmpdir, 'project-files-*.zip')]
    File.delete(@file.diskfile)
    @session.get("/project_files/#{@file.id}/download")
    assert_equal 404, @session.response.status
    archive(:attachment_ids => [@file.id])
    assert_equal 404, @session.response.status
  end

  def test_anonymous_access_and_csrf_protection
    anonymous = ActionDispatch::Integration::Session.new(Rails.application)
    anonymous.host! 'localhost'
    anonymous.get('/project_files')
    assert_equal 302, anonymous.response.status
    anonymous.get("/project_files/#{@file.id}/download")
    assert_equal 302, anonymous.response.status
    @session.post('/project_files/archive', :params => {:attachment_ids => [@file.id]})
    assert_equal 422, @session.response.status
  end

  def test_multiple_projects_pagination_and_all_filtered
    Member.create!(:project => @other, :principal => @user, :roles => [@role])
    # Copies share the same physical file, as Redmine attachment copies do.
    51.times do |n|
      a = @file.dup
      a.filename = "copy-#{n}.txt"
      a.save!
    end
    @session.get('/project_files')
    assert_equal 200, @session.response.status
    assert_equal 50, Nokogiri::HTML(@session.response.body).css('.project-file-selection').size
    @session.get('/project_files', :params => {:page => 2})
    assert_equal 3, Nokogiri::HTML(@session.response.body).css('.project-file-selection').size
    archive(:all_filtered => '1')
    assert_equal 200, @session.response.status
    entries = []
    Zip::InputStream.open(StringIO.new(@session.response.body)) do |zip|
      while (entry = zip.get_next_entry)
        entries << entry.name
      end
    end
    assert_equal 53, entries.size
    assert entries.any? { |name| name.include?('other.txt') }
    refute entries.any? { |name| name.include?('secret.txt') }
  end

  def test_group_membership_grants_catalogue_permission
    group = Group.create!(:lastname => 'File readers')
    group.users << @user
    Member.where(:project => @project, :user_id => @user.id).destroy_all
    Member.create!(:project => @project, :principal => group, :roles => [@role])
    @session.get('/project_files')
    assert_equal 200, @session.response.status
    assert_includes @session.response.body, 'пример.txt'
    @session.get("/projects/#{@project.identifier}/files")
    assert_equal 403, @session.response.status
    @role.add_permission! :view_files
    @session.get("/projects/#{@project.identifier}/files")
    assert_equal 200, @session.response.status
  end

end
