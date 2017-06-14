require_relative 'spec_helper'

describe ReportResponse do
  let(:repo)  { Repository.create_from_json(JSONModel(:repository).from_hash(:repo_code => "TESTREPO",
                                                                      :name => "My new test repository")) }
  let(:datab) { Sequel.connect(AppConfig[:db_url]) }
  let(:deacc_job) { Job.create_from_json(build(:json_deaccession_job),
                       :repo_id => repo.id,
                       :user => create_nobody_user) }
  let(:report) { AccessionDeaccessionsListReport.new({:repo_id => repo.id, :format => 'csv'},
                                deacc_job,
                                datab) }
  let(:resp) { ReportResponse.new(report, {format: 'csv'} ) }
  it 'initializes with the correct params' do
    expect(resp.report).to eq(report)
    expect(resp.params).to eq({format: 'csv'})
  end
  it 'generates the required response' do
    puts "Response #{resp.generate.inspect}"
  end
end
