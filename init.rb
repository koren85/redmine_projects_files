Redmine::Plugin.register :redmine_project_files do
  name 'Project Files'
  author 'Project Files contributors'
  description 'A permission-controlled attachment catalogue and ZIP downloads'
  version '1.0.0'
  requires_redmine :version_or_higher => '4.1.0'

  project_module :project_files do
    permission :download_project_files, {:project_files => [:index, :download, :archive]}, :require => :member
    permission :download_all_project_files, {}, :require => :member
  end
  menu :application_menu, :project_files, {:controller => 'project_files', :action => 'index'},
       :caption => :label_project_files, :if => Proc.new { User.current.logged? && Project.allowed_to(User.current, :download_project_files).exists? }
  menu :project_menu, :project_files, {:controller => 'project_files', :action => 'index'},
       :caption => :label_project_files, :param => :project_id
end
