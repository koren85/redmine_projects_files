get 'project_files', :to => 'project_files#index', :as => :project_file_catalogue
get 'projects/:project_id/project_files', :to => 'project_files#index', :as => :project_file_catalogue_for_project
get 'project_files/:id/download', :to => 'project_files#download', :as => :download_project_file
post 'project_files/archive', :to => 'project_files#archive', :as => :archive_project_files
