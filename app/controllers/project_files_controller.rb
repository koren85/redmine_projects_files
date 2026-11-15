require 'zip'
require 'tempfile'
require_dependency 'project_files/archive_body'

class ProjectFilesController < ApplicationController
  before_action :require_login
  before_action :prepare_catalogue
  MAX_FILES = 500
  MAX_BYTES = 512 * 1024 * 1024

  def index
    @ids = @catalogue.visible_ids
    @attachment_count = @ids.size
    @page = [params[:page].to_i, 1].max
    @pages = [(@attachment_count / 50.0).ceil, 1].max
    @page = [@page, @pages].min
    @attachments = Attachment.where(:id => @ids.slice((@page - 1) * 50, 50)).includes(:container, :author).order(:id => :desc)
    # Options come only from accessible attachments, even on the global page.
    authors = Attachment.where(:id => @ids).distinct.pluck(:author_id)
    @authors = User.where(:id => authors).sorted
    @groups = Group.joins(:users).where(:users => {:id => authors}).distinct.sorted
    @roles = Role.givable.sorted
  end

  def download
    attachment = Attachment.find_by_id(params[:id])
    return render_404 unless attachment && @catalogue.permitted?(attachment) && attachment.readable?
    response.headers['Cache-Control'] = 'private, no-store'
    send_file attachment.diskfile, :filename => filename_for_content_disposition(attachment.filename),
              :type => 'application/octet-stream', :disposition => 'attachment'
  end

  def archive
    if params[:all_filtered] == '1'
      ids = @catalogue.visible_ids
    else
      raw = Array(params[:attachment_ids]).reject(&:blank?)
      return archive_error(:error_project_files_limit) if raw.size > MAX_FILES
      return render_404 unless raw.all? { |id| id.to_s.match?(/\A[1-9]\d*\z/) }
      ids = raw.map(&:to_i).uniq
    end
    return archive_error(:error_project_files_empty) if ids.empty?
    return archive_error(:error_project_files_limit) if ids.size > MAX_FILES
    attachments = Attachment.where(:id => ids).includes(:container).order(:id).to_a
    # Re-authorize every ID at download time; never silently skip forbidden files.
    return render_404 unless attachments.size == ids.size && attachments.all? { |a| @catalogue.permitted?(a) && a.readable? }
    return archive_error(:error_project_files_limit) if attachments.sum { |a| [a.filesize, File.size(a.diskfile)].max } > MAX_BYTES
    file = Tempfile.new(['project-files-', '.zip'])
    delivered = false
    begin
      Zip::OutputStream.open(file.path) do |zip|
        attachments.each do |attachment|
          name = attachment.filename.to_s.encode('UTF-8', :invalid => :replace, :undef => :replace).gsub(/[\\\/\x00-\x1f\x7f]/, '_')
          entry = Zip::Entry.new('', "#{attachment.project.id}/#{attachment.id}_#{name}")
          entry.gp_flags |= Zip::Entry::EFS
          zip.put_next_entry(entry)
          File.open(attachment.diskfile, 'rb') do |input|
            while (chunk = input.read(64 * 1024))
              zip.write(chunk)
            end
          end
        end
      end
      response.headers['Content-Type'] = 'application/zip'
      response.headers['Content-Disposition'] = 'attachment; filename="project-files.zip"'
      response.headers['Content-Length'] = File.size(file.path).to_s
      response.headers['Cache-Control'] = 'private, no-store'
      self.response_body = ProjectFiles::ArchiveBody.new(file)
      delivered = true
    ensure
      file.close! unless delivered
    end
  rescue Errno::ENOENT, Errno::EACCES
    render_404
  end

  private

  def prepare_catalogue
    @filters = params.permit(:project_id, :issue_id, :author_id, :group_id, :role_id).to_h.symbolize_keys
    @catalogue = ProjectFileCatalogue.new(User.current, @filters)
    @projects = @catalogue.projects
    if params[:project_id].present?
      @project = @projects.detect { |project| project.id.to_s == params[:project_id] || project.identifier == params[:project_id] }
      return render_403 unless @project
      @filters[:project_id] = @project.id
      @catalogue = ProjectFileCatalogue.new(User.current, @filters)
    end
    render_403 if @projects.empty?
  end

  def archive_error(key)
    render :plain => l(key), :status => :unprocessable_entity
  end
end
