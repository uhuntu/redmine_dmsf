# encode: utf-8
# frozen_string_literal: true
#
# Redmine plugin for Document Management System "Features"
#
# Copyright © 2011-22 Karel Pičman <karel.picman@kontron.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#

class DmsfQuery < Query

  attr_accessor :dmsf_folder_id, :deleted, :sub_projects

  self.queried_class = DmsfFolder
  self.view_permission = :view_dmsf_files

  # Standard columns
  self.available_columns = [
    QueryColumn.new(:id, sortable: 'id', caption: +'#'),
    DmsfTitleQueryColumn.new(:title, sortable: 'title', frozen: true, caption: :label_column_title),
    QueryColumn.new(:size, sortable: 'size', caption: :label_column_size),
    DmsfModifiedQueryColumn.new(:modified, sortable: 'updated', caption: :label_column_modified),
    DmsfVersionQueryColumn.new(:version, sortable: %(major_version minor_version patch_version),
      caption: :label_column_version),
    QueryColumn.new(:workflow, sortable: 'workflow', caption: :label_column_workflow),
    QueryColumn.new(:author, sortable: %(firstname lastname), caption: :label_column_author),
    QueryColumn.new(:description, sortable: 'description', caption: :label_column_description),
    QueryColumn.new(:comment, sortable: 'comment', caption: :label_column_comment)
  ]

  def initialize(attributes=nil, *args)
    super attributes
    self.sort_criteria = []
    self.filters ||= { 'title' => { operator: '~', values: ['']} }
    self.dmsf_folder_id = nil
    self.deleted = false
    self.sub_projects = false
  end

  ######################################################################################################################
  # Inherited
  #

  def available_columns
    unless @available_columns
      @available_columns = self.class.available_columns.dup
      @available_columns += DmsfFileRevisionCustomField.visible.collect do |cf|
        c = QueryCustomFieldColumn.new(cf)
        # We would like to prevent grouping in the Option form
        c.groupable = false
        c
      end
    end
    @available_columns
  end

  def default_columns_names
    unless @default_column_names
      @default_column_names = []
      columns = available_columns
      if columns
        columns.each do |column|
          if column.is_a?(QueryCustomFieldColumn)
            name = column.custom_field.name
          else
            name = column.name.to_s
          end
          if DmsfFolder.is_column_on?(name)
            @default_column_names << column.name
          end
        end
      end
    end
    @default_column_names
  end

  def default_sort_criteria
    [%(title ASC)]
  end

  def base_scope
    unless @scope
      @scope = [dmsf_folders_scope, dmsf_folder_links_scope, dmsf_projects_scope, dmsf_files_scope,
                dmsf_file_links_scope, dmsf_url_links_scope].compact.inject(:union_all)
    end
    @scope
  end

  # Returns the count of all items
  def dmsf_count
    # We cannot use this due to the permissions
    #base_scope.where(statement).count
    dmsf_nodes.size
  rescue ::ActiveRecord::StatementInvalid => e
    raise StatementInvalid.new e.message
  end

  def initialize_available_filters
    add_available_filter 'author', type: :list, values: lambda { author_values }
    add_available_filter 'title', type: :text
    add_available_filter 'updated', type: :date_past
    add_available_filter 'locked', type: :list, values: [[l(:general_text_yes), '1'], [l(:general_text_no), '0']]
    add_available_filter 'workflow', type: :list, values: [[l(:title_waiting_for_approval), '1'],
      [l(:title_approved), '2'], [l(:title_assigned), '3'], [l(:title_rejected), '4'], [l(:title_obsolete), '5']]
    add_custom_fields_filters DmsfFileRevisionCustomField.visible
  end

  def statement
    unless @statement
      filters_clauses = []
      filters.each_key do |field|
        v = values_for(field).clone
        next unless v && !v.empty?
        operator = operator_for(field)
        case field
        when 'author'
          if v.delete('me')
            v.push User.current.id.to_s
          end
        when 'title'
          next if (operator == '~') && v.join.empty?
        end
        if field =~ /cf_(\d+)$/
          # custom field
          available_filters # Initialize available filters #1380
          sql_cf = +sql_for_custom_field(field, operator, v, $1)
          # This is what we get
          # dmsf_folders.id  IN (SELECT dmsf_folders.id FROM dmsf_folders LEFT OUTER JOIN custom_values ON custom_values.customized_type='DmsfFolder' AND custom_values.customized_id=dmsf_folders.id AND custom_values.custom_field_id=1 WHERE (custom_values.value IN ('tag 1')) AND (1=1))
          # This is what we need
          # dmsf_folders.customized_id  IN (SELECT customized_id FROM custom_values WHERE customized_type=dmsf_folders.customized_type AND customized_id=dmsf_folders.customized_id AND custom_field_id=1 AND value IN ('tag 1'))
          sql_cf.gsub!(' AND (1=1)', '')
          sql_cf.gsub!(/^dmsf_folders.id/, 'dmsf_folders.customized_id')
          sql_cf.gsub!(
            "IN (SELECT dmsf_folders.id FROM dmsf_folders LEFT OUTER JOIN custom_values ON custom_values.customized_type='DmsfFolder' AND custom_values.customized_id=dmsf_folders.id AND custom_values.custom_field_id=",
            "IN (SELECT customized_id FROM custom_values WHERE customized_type=dmsf_folders.customized_type AND customized_id=dmsf_folders.customized_id AND custom_field_id="
          )
          sql_cf.gsub!('WHERE (', 'AND ')
          sql_cf.gsub!(/\)$/, '')
          filters_clauses << sql_cf
        else
          filters_clauses << '(' + sql_for_field(field, operator, v, queried_table_name, field) + ')'
        end
      end
      filters_clauses.reject!(&:blank?)
      @statement = filters_clauses.any? ? filters_clauses.join(' AND ') : nil
    end
    @statement
  end

  def validate_query_filters
    # Skip validation for empty title (default filter)
    filter = filters.delete('title')
    super
    # Add it back
    filters['title'] = filter if filter
  end

  def columns
    cols = super
    # Just move the optional column Id to the beginning as it isn't frozen
    id_index = cols.index { |col| col.name == :id }
    if id_index == 1
      id_col = cols.delete_at(id_index)
      cols.insert 0, id_col
    end
    cols
  end

  ######################################################################################################################
  # New

  def dmsf_nodes(options={})
    order_option = ['sort', group_by_sort_order, (options[:order] || sort_clause&.first)].flatten.reject(&:blank?)
    if order_option.size > 1
      DmsfFileRevisionCustomField.visible.pluck(:id, :name).each do |id, name|
        order_option[1].gsub! "cf_#{id}.value", "cf_#{id}"
      end
      if order_option[1] =~ /^(firstname|major_version),? (lastname|minor_version)( patch_version)? (DESC|ASC)$/
        order_option[1] = $3.present? ? "#{$1} #{$4}, #{$2} #{$4}, #{$3} #{$4}" : "#{$1} #{$4}, #{$2} #{$4}"
      end
    end
    case ActiveRecord::Base.connection.adapter_name.downcase
    when /sqlserver/i
      # This is just a workaround for #1352.
      # limit and offset cause an error in case of MS SQL
      items = base_scope.
        where(statement).
        order(order_option).to_a
    else
      items = base_scope.
        where(statement).
        order(order_option).
        limit(options[:limit]).
        offset(options[:offset]).to_a
    end
    fo = filters_on?
    items.delete_if do |item|
      case item.type
      when 'project'
        prj  = Project.find_by(id: item.id)
        !prj&.dmsf_available?
      when 'folder'
        dmsf_folder = DmsfFolder.find_by(id: item.id)
        !DmsfFolder.permissions?(dmsf_folder, false)
      when 'file'
        if fo
          dmsf_file = DmsfFile.find_by(id: item.id)
          if dmsf_file.dmsf_folder
            !DmsfFolder.permissions?(dmsf_file.dmsf_folder, false)
          else
            !dmsf_file.project.dmsf_available?
          end
        else
          false
        end
      when /link$/
        if fo
          dmsf_link = DmsfLink.find_by(id: item.id)
          if dmsf_link.dmsf_folder
            !dmsf_link.dmsf_folder.visible?
            !DmsfFolder.permissions?(dmsf_link.dmsf_folder, false)
          else
            !dmsf_link.project.dmsf_available?
          end
        else
          false
        end
      end
    end
    items
  end

  def extra_columns
    []
  end

  private

  def filters_on?
    filters.each_key do |field|
      if values_for(field).any?{ |value| value.present? }
        return true
      end
    end
    return false
  end

  def sub_query
    case ActiveRecord::Base.connection.adapter_name.downcase
    when /sqlserver/i
      'dmsf_file_revisions.id = (SELECT TOP 1 r.id FROM dmsf_file_revisions r WHERE r.created_at = (SELECT MAX(created_at) FROM dmsf_file_revisions rr WHERE rr.dmsf_file_id = dmsf_files.id) AND r.dmsf_file_id = dmsf_files.id ORDER BY id DESC)'
    else
      'dmsf_file_revisions.id = (SELECT r.id FROM dmsf_file_revisions r WHERE r.created_at = (SELECT MAX(created_at) FROM dmsf_file_revisions rr WHERE rr.dmsf_file_id = dmsf_files.id) AND r.dmsf_file_id = dmsf_files.id ORDER BY id DESC LIMIT 1)'
    end
  end
  
  def get_integer_type
    if Redmine::Database.mysql?
      ActiveRecord::Base.connection.type_to_sql(:signed)
    else
      ActiveRecord::Base.connection.type_to_sql(:integer)
    end
  end

  def now
    case ActiveRecord::Base.connection.adapter_name.downcase
    when /sqlserver/i
      'GETDATE()'
    when /sqlite/i
      "datetime('now')"
    else
      'NOW()'
    end
  end

  def get_cf_query(id, type, table)
    if Redmine::Database.mysql? || Redmine::Database.sqlite?
      aggr_func = 'GROUP_CONCAT(value)'
    else
      aggr_func = "STRING_AGG(value, ',')"
    end
    ",(SELECT #{aggr_func} FROM custom_values WHERE custom_field_id = #{id} AND customized_type = '#{type}' AND customized_id = #{table}.id GROUP BY custom_field_id) AS cf_#{id}"
  end

  def dmsf_projects_scope
    return nil unless sub_projects
    cf_columns = +''
    DmsfFileRevisionCustomField.visible.order(:position).pluck(:id).each do |id|
      cf_columns << ",NULL AS cf_#{id}"
    end
    scope = Project.select(%{
        projects.id AS id,
        projects.id AS project_id,
        CAST(NULL AS #{get_integer_type}) AS revision_id,
        projects.name AS title,
        projects.identifier AS filename,
        CAST(NULL AS #{get_integer_type}) AS size,
        projects.updated_on AS updated,
        CAST(NULL AS #{get_integer_type}) AS major_version,
        CAST(NULL AS #{get_integer_type}) AS minor_version,
        CAST(NULL AS #{get_integer_type}) AS patch_version,
        CAST(NULL AS #{get_integer_type}) AS workflow,
        CAST(NULL AS #{get_integer_type}) AS workflow_id,
        '' AS firstname,
        '' AS lastname,
        CAST(NULL AS #{get_integer_type}) AS author,
        'project' AS type,
        CAST(0 AS #{get_integer_type}) AS deleted,
        '' AS customized_type,
        0 AS customized_id,
        projects.description AS description,
        '' AS comment,
        0 AS locked,
        0 AS sort#{cf_columns}}).visible
    if dmsf_folder_id || deleted
      scope.none
    else
      scope = scope.non_templates if scope.respond_to?(:non_templates)
      if project.nil? && filters_on?
        scope
      else
        scope.where projects: { parent_id: project&.id }
      end
    end
  end

  def dmsf_folders_scope
    cf_columns = +''
    DmsfFileRevisionCustomField.visible.order(:position).pluck(:id).each do |id|
      cf_columns << get_cf_query(id, 'DmsfFolder', 'dmsf_folders')
    end
    scope = DmsfFolder.select(%{
        dmsf_folders.id AS id,
        dmsf_folders.project_id AS project_id,
        CAST(NULL AS #{get_integer_type}) AS revision_id,
        dmsf_folders.title AS title,
        NULL AS filename,
        CAST(NULL AS #{get_integer_type}) AS size,
        dmsf_folders.updated_at AS updated,
        CAST(NULL AS #{get_integer_type}) AS major_version,
        CAST(NULL AS #{get_integer_type}) AS minor_version,
        CAST(NULL AS #{get_integer_type}) AS patch_version,
        CAST(NULL AS #{get_integer_type}) AS workflow,
        CAST(NULL AS #{get_integer_type}) AS workflow_id,
        users.firstname AS firstname,
        users.lastname AS lastname,
        users.id AS author,
        'folder' AS type,
        dmsf_folders.deleted AS deleted,
        'DmsfFolder' AS customized_type,
        dmsf_folders.id AS customized_id,
        dmsf_folders.description AS description,
        '' AS comment,
        (case when dmsf_locks.id IS NULL then 0 else 1 end) AS locked,
        1 AS sort#{cf_columns}}).
      joins('LEFT JOIN users ON dmsf_folders.user_id = users.id').
      joins("LEFT JOIN dmsf_locks ON dmsf_folders.id = dmsf_locks.entity_id AND dmsf_locks.entity_type = 1 AND
        (dmsf_locks.expires_at IS NULL OR dmsf_locks.expires_at > #{now})")
    if deleted
      scope = scope.deleted
    else
      scope = scope.visible
    end
    if dmsf_folder_id
      scope.where dmsf_folders: { dmsf_folder_id: dmsf_folder_id }
    else
      if project.nil? && filters_on?
        scope
      else
        if statement.present? || deleted
          scope.where dmsf_folders: { project_id: project&.id }
        else
          scope.where dmsf_folders: { project_id: project&.id, dmsf_folder_id: nil }
        end
      end
    end
  end

  def dmsf_folder_links_scope
    cf_columns = +''
    DmsfFileRevisionCustomField.visible.order(:position).pluck(:id).each do |id|
      cf_columns << get_cf_query(id, 'DmsfFolder', 'dmsf_folders')
    end
    scope = DmsfLink.select(%{
        dmsf_links.id AS id,
        dmsf_links.target_project_id AS project_id,
        dmsf_links.target_id AS revision_id,
        dmsf_links.name AS title,
        dmsf_folders.title AS filename,
        CAST(NULL AS #{get_integer_type}) AS size,
        COALESCE(dmsf_folders.updated_at, dmsf_links.updated_at) AS updated,
        CAST(NULL AS #{get_integer_type}) AS major_version,
        CAST(NULL AS #{get_integer_type}) AS minor_version,
        CAST(NULL AS #{get_integer_type}) AS patch_version,
        CAST(NULL AS #{get_integer_type}) AS workflow,
        CAST(NULL AS #{get_integer_type}) AS workflow_id,
        users.firstname AS firstname,
        users.lastname AS lastname,
        users.id AS author,
        'folder-link' AS type,
        dmsf_links.deleted AS deleted,
        'DmsfFolder' AS customized_type,
        dmsf_folders.id AS customized_id,
        dmsf_folders.description AS description,
        '' AS comment,
        (case when dmsf_locks.id IS NULL then 0 else 1 end) AS locked,
        1 AS sort#{cf_columns}}).
      joins('LEFT JOIN dmsf_folders ON dmsf_links.target_id = dmsf_folders.id').
      joins('LEFT JOIN users ON users.id = COALESCE(dmsf_folders.user_id, dmsf_links.user_id)').
      joins("LEFT JOIN dmsf_locks ON dmsf_folders.id = dmsf_locks.entity_id AND dmsf_locks.entity_type = 1 AND
        (dmsf_locks.expires_at IS NULL OR dmsf_locks.expires_at > #{now})")
    if deleted
      scope = scope.deleted
    else
      scope = scope.visible
    end
    if dmsf_folder_id
      scope.where dmsf_links: { target_type: 'DmsfFolder', dmsf_folder_id: dmsf_folder_id}
    else
      if project.nil? && filters_on?
        scope
      else
        if statement.present? || deleted
          scope.where dmsf_links: { target_type: 'DmsfFolder', project_id: project&.id }
        else
          scope.where dmsf_links: { target_type: 'DmsfFolder', project_id: project&.id, dmsf_folder_id: nil }
        end
      end
    end
  end

  def dmsf_files_scope
    cf_columns = +''
    DmsfFileRevisionCustomField.visible.order(:position).pluck(:id).each do |id|
      cf_columns << get_cf_query(id, 'DmsfFileRevision', 'dmsf_file_revisions')
    end
    scope = DmsfFile.select(%{
        dmsf_files.id AS id,
        dmsf_files.project_id AS project_id,
        dmsf_file_revisions.id AS revision_id,
        dmsf_file_revisions.title AS title,
        dmsf_file_revisions.name AS filename,
        dmsf_file_revisions.size AS size,
        dmsf_file_revisions.updated_at AS updated,
        dmsf_file_revisions.major_version AS major_version,
        dmsf_file_revisions.minor_version AS minor_version,
        dmsf_file_revisions.patch_version AS patch_version,
        dmsf_file_revisions.workflow AS workflow,
        dmsf_file_revisions.dmsf_workflow_id AS workflow_id,
        users.firstname AS firstname,
        users.lastname AS lastname,
        users.id AS author,
        'file' AS type,
        dmsf_files.deleted AS deleted,
        'DmsfFileRevision' AS customized_type,
        dmsf_file_revisions.id AS customized_id,
        dmsf_file_revisions.description AS description,
        dmsf_file_revisions.comment AS comment,
        (case when dmsf_locks.id IS NULL then 0 else 1 end) AS locked,
        2 AS sort#{cf_columns}}).
      joins(:dmsf_file_revisions).
      joins('LEFT JOIN users ON dmsf_file_revisions.user_id = users.id ').
      joins("LEFT JOIN dmsf_locks ON dmsf_files.id = dmsf_locks.entity_id AND dmsf_locks.entity_type = 0 AND
        (dmsf_locks.expires_at IS NULL OR dmsf_locks.expires_at > #{now})").
      where(sub_query)
      if deleted
        scope = scope.deleted
      else
        scope = scope.visible
      end
      if dmsf_folder_id
        scope.where dmsf_files: { dmsf_folder_id: dmsf_folder_id }
      else
        if project.nil? && filters_on?
          scope
        else
          if statement.present? || deleted
            scope.where dmsf_files: { project_id: project&.id }
          else
            scope.where(dmsf_files: { project_id: project&.id, dmsf_folder_id: nil })
          end
        end
      end
  end

  def dmsf_file_links_scope
    cf_columns = +''
    DmsfFileRevisionCustomField.visible.order(:position).pluck(:id).each do |id|
      cf_columns << get_cf_query(id, 'DmsfFileRevision', 'dmsf_file_revisions')
    end
    scope = DmsfLink.select(%{
        dmsf_links.id AS id,
        dmsf_files.project_id AS project_id,
        dmsf_files.id AS revision_id,
        dmsf_links.name AS title,
        dmsf_file_revisions.name AS filename,
        dmsf_file_revisions.size AS size,
        dmsf_file_revisions.updated_at AS updated,
        dmsf_file_revisions.major_version AS major_version,
        dmsf_file_revisions.minor_version AS minor_version,
        dmsf_file_revisions.patch_version AS patch_version,
        dmsf_file_revisions.workflow AS workflow,
        dmsf_file_revisions.dmsf_workflow_id AS workflow_id,
        users.firstname AS firstname,
        users.lastname AS lastname,
        users.id AS author,
        'file-link' AS type,
        dmsf_links.deleted AS deleted,
        'DmsfFileRevision' AS customized_type,
        dmsf_file_revisions.id AS customized_id,
        dmsf_file_revisions.description AS description,
        dmsf_file_revisions.comment AS comment,
        (case when dmsf_locks.id IS NULL then 0 else 1 end) AS locked,
        2 AS sort#{cf_columns}}).
      joins('JOIN dmsf_files ON dmsf_files.id = dmsf_links.target_id').
      joins('JOIN dmsf_file_revisions ON dmsf_file_revisions.dmsf_file_id = dmsf_files.id').
      joins('LEFT JOIN users ON dmsf_file_revisions.user_id = users.id ').
      joins("LEFT JOIN dmsf_locks ON dmsf_files.id = dmsf_locks.entity_id AND dmsf_locks.entity_type = 0 AND
        (dmsf_locks.expires_at IS NULL OR dmsf_locks.expires_at > #{now})").
      where(sub_query)
    if deleted
      scope = scope.deleted
    else
      scope = scope.visible
    end
    if dmsf_folder_id
      scope.where dmsf_links: { target_type: 'DmsfFile', dmsf_folder_id: dmsf_folder_id }
    else
      if project.nil? && filters_on?
        scope
      else
        if statement.present? || deleted
          scope.where dmsf_links: { target_type: 'DmsfFile', project_id: project&.id }
        else
          scope.where dmsf_links: { target_type: 'DmsfFile', project_id: project&.id, dmsf_folder_id: nil }
        end
      end
    end

  end

  def dmsf_url_links_scope
    cf_columns = +''
    DmsfFileRevisionCustomField.visible.order(:position).pluck(:id).each do |id|
      cf_columns << ",NULL AS cf_#{id}"
    end
    scope = DmsfLink.select(%{
        dmsf_links.id AS id,
        dmsf_links.project_id AS project_id,
        CAST(NULL AS #{get_integer_type}) AS revision_id,
        dmsf_links.name AS title,
        dmsf_links.external_url AS filename,
        CAST(NULL AS #{get_integer_type}) AS size,
        dmsf_links.updated_at AS updated,
        CAST(NULL AS #{get_integer_type}) AS major_version,
        CAST(NULL AS #{get_integer_type}) AS minor_version,
        CAST(NULL AS #{get_integer_type}) AS patch_version,
        CAST(NULL AS #{get_integer_type}) AS workflow,
        CAST(NULL AS #{get_integer_type}) AS workflow_id,
        users.firstname AS firstname,
        users.lastname AS lastname,
        users.id AS author,
        'url-link' AS type,
        dmsf_links.deleted AS deleted,
        '' AS customized_type,
        0 AS customized_id,
        '' AS description,
        '' AS comment,
        0 AS locked,
        2 AS sort#{cf_columns}}).
      joins('LEFT JOIN users ON dmsf_links.user_id = users.id ')
    if deleted
      scope = scope.deleted
    else
      scope = scope.visible
    end
    if dmsf_folder_id
      scope.where dmsf_links: { target_type: 'DmsfUrl', dmsf_folder_id: dmsf_folder_id }
    else
      if project.nil? && filters_on?
        scope
      else
        if statement.present? || deleted
          scope.where dmsf_links: { target_type: 'DmsfUrl', project_id: project&.id }
        else
          scope.where dmsf_links: { target_type: 'DmsfUrl', project_id: project&.id, dmsf_folder_id: nil }
        end
      end
    end
  end

  def self.default(project = nil, user = User.current)
    # User's default
    if user&.logged? && (query_id = user.pref.default_dmsf_query).present?
      query = find_by(id: query_id)
      return query if query&.visible?
    end

    # Project's default
    project = project[:project] if project&.is_a?(Hash)
    query = project&.default_dmsf_query
    return query if query&.visibility == VISIBILITY_PUBLIC

    # Global default
    if (query_id = Setting.plugin_redmine_dmsf['dmsf_default_query']).present?
      query = find_by(id: query_id)
      return query if query&.visibility == VISIBILITY_PUBLIC
    end
    nil
  end

end
