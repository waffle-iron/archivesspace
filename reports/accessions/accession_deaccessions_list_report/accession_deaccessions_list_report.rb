class AccessionDeaccessionsListReport < AbstractReport

  register_report

  def template
    'accession_deaccessions_list_report.erb'
  end

  def headers
    [ 'accessionId', 'repo_id', 'accessionNumber', 'title', 'accessionDate',
      'containerSummary', 'extentNumber', 'extentType', 'deaccessionId',
      'de_description', 'de_notification', 'deaccessionDate', 'de_extentNumber',
      'de_extentType']
  end

  def query
    acc = accessions_query
    acc.each do | a |
      de = deaccessions_query(a[:accessionId])
      if de.all.length > 0 && ['csv', 'json', 'xslx'].include?(params[:format])
        de.each do | d |
          a.merge!d
        end
      end
    end
  end

  def accessions_query
    db[:accession].
      select(Sequel.as(:id, :accessionId),
             Sequel.as(:repo_id, :repo_id),
             Sequel.as(:identifier, :accessionNumber),
             Sequel.as(:title, :title),
             Sequel.as(:accession_date, :accessionDate),
             Sequel.as(Sequel.lit('GetAccessionContainerSummary(id)'), :containerSummary),
             Sequel.as(Sequel.lit('GetAccessionExtent(id)'), :extentNumber),
             Sequel.as(Sequel.lit('GetAccessionExtentType(id)'), :extentType))
  end

  def deaccessions_query(acc_id)
      db[:deaccession]
        .filter(:accession_id => acc_id)
        .select(Sequel.as(:id, :deaccessionId),
                Sequel.as(:accession_id, :accessionId),
                Sequel.as(:description, :de_description),
                Sequel.as(:notification, :de_notification),
                Sequel.as(Sequel.lit("GetDeaccessionDate(id)"), :deaccessionDate),
                Sequel.as(Sequel.lit("GetDeaccessionExtent(id)"), :de_extentNumber),
                Sequel.as(Sequel.lit("GetDeaccessionExtentType(id)"), :de_extentType))
  end

  # Accessioned Between - From Date
  def from_date
    @from_date ||= self.accessions_query.min(:accession_date)
  end

  # Accessioned Between - To Date
  def to_date
    @to_date ||= self.accessions_query.max(:accession_date)
  end

  # Total Extent of Deaccessions
  def total_extent_of_deaccessions
    return @total_extent_of_deaccessions if @total_extent_of_deaccessions

    deaccessions = db[:deaccession].where(:accession_id => self.query.select(:id))
    deaccession_extents = db[:extent].where(:deaccession_id => deaccessions.select(:id))

    @total_extent_of_deaccessions = deaccession_extents.sum(:number)
  end

end
