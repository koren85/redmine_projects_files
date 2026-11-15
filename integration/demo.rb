# Optional DEMO ONLY. Creates data in the database selected by RAILS_ENV.
require 'stringio'
ActionMailer::Base.perform_deliveries = false
raise 'Demo already exists' if User.find_by_login('files_demo')
role = Role.create!(:name => 'Каталог файлов (демо)', :permissions => [:view_project, :view_issues, :view_files, :download_project_files], :issues_visibility => 'default')
user = User.create!(:login => 'files_demo', :firstname => 'Демо', :lastname => 'Файлы', :mail => 'files_demo@example.test', :language => 'ru', :password => 'Demo-files-41!', :password_confirmation => 'Demo-files-41!')
project = Project.create!(:name => 'Документы проекта', :identifier => 'files-demo', :is_public => false,
  :enabled_module_names => %w(issue_tracking files project_files), :trackers => [Tracker.first])
Member.create!(:project => project, :principal => user, :roles => [role])
[ ['Техническое задание', 'техническое-задание.txt', 'Техническое задание проекта'],
  ['Отчёт за ноябрь', 'отчёт.csv', "Задача,Статус\nРазработка,Готово\nПроверка,Готово"],
  ['Инструкция', 'инструкция.txt', 'Инструкция по работе с проектом'] ].each do |subject, name, text|
  issue = Issue.create!(:project => project, :tracker => Tracker.first, :status => IssueStatus.first, :priority => IssuePriority.first, :author => user, :subject => subject)
  io = StringIO.new(text)
  io.define_singleton_method(:original_filename) { name }
  io.define_singleton_method(:content_type) { 'text/plain' }
  Attachment.create!(:container => issue, :author => user, :file => io)
end
puts 'Demo ready: files_demo / Demo-files-41!'
