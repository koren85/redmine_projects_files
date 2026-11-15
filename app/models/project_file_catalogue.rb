# This class only reads Redmine records; no patches or schema changes.
class ProjectFileCatalogue
  TYPES = %w(Issue Document Version Project WikiPage News Message).freeze
  attr_reader :projects

  def initialize(user, filters = {})
    @user, @filters = user, filters
    @projects = Project.allowed_to(user, :download_project_files).active.order(:name).to_a
    @project_ids = @projects.map(&:id)
    @all_ids = @projects.select { |p| user.allowed_to?(:download_all_project_files, p) }.map(&:id)
  end

  def permitted?(attachment)
    return false unless TYPES.include?(attachment.container_type)
    project = attachment.project
    project && @project_ids.include?(project.id) &&
      (@all_ids.include?(project.id) || attachment.visible?(@user))
  end

  def scope
    ids = @project_ids
    ids &= [@filters[:project_id].to_i] if @filters[:project_id].present?
    return Attachment.none if ids.empty?
    parts = TYPES.map do |type|
      relation = case type
                 when 'Project' then Project.where(:id => ids)
                 when 'WikiPage' then WikiPage.joins(:wiki).where(:wikis => {:project_id => ids})
                 when 'Message' then Message.joins(:board).where(:boards => {:project_id => ids})
                 else type.constantize.where(:project_id => ids)
                 end
      "(attachments.container_type = '#{type}' AND attachments.container_id IN (#{relation.select("#{type.constantize.table_name}.id").to_sql}))"
    end
    result = Attachment.where(parts.join(' OR '))
    if @filters[:issue_id].present?
      result = result.where(:container_type => 'Issue', :container_id => @filters[:issue_id].to_i)
    end
    result = result.where(:author_id => @filters[:author_id].to_i) if @filters[:author_id].present?
    if @filters[:group_id].present?
      result = result.where(:author_id => Group.find_by_id(@filters[:group_id].to_i).try(:users).try(:select, :id) || [])
    end
    if @filters[:role_id].present?
      # Roles belong to membership in the attachment's project, not any project.
      by_role = ids.map do |project_id|
        members = Member.joins(:member_roles).where(:project_id => project_id,
                    :member_roles => {:role_id => @filters[:role_id].to_i}).select(:user_id)
        scoped = self.class.new(@user, @filters.except(:role_id).merge(:project_id => project_id)).scope
        result.where(:id => scoped.select(:id), :author_id => members)
      end
      result = by_role.reduce { |a, b| a.or(b) }
    end
    result
  end

  def visible_ids
    ids = []
    scope.includes(:container, :author).find_each(:batch_size => 250) do |attachment|
      ids << attachment.id if permitted?(attachment)
    end
    ids.sort.reverse
  end
end
