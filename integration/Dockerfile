FROM redmine:4.1.7
COPY . /usr/src/redmine/plugins/redmine_project_files
RUN bundle install --without development test
