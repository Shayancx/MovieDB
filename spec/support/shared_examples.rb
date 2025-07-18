# frozen_string_literal: true

# Shared examples for common patterns
RSpec.shared_examples "a paginated endpoint" do |endpoint|
  it "returns paginated results" do
    get endpoint
    expect(last_response).to be_ok
    body = JSON.parse(last_response.body)
    expect(body).to be_an(Array)
  end

  it "respects page parameter" do
    get "#{endpoint}?page=2"
    expect(last_response).to be_ok
  end

  it "respects per_page parameter" do
    get "#{endpoint}?per_page=10"
    expect(last_response).to be_ok
  end
end

RSpec.shared_examples "a filterable resource" do |resource_type|
  it "filters by search query" do
    results = described_class.filtered(search: 'test')
    expect(results).to be_an(Array)
  end

  it "filters by multiple criteria" do
    results = described_class.filtered(
      search: 'test',
      genre: 'Action',
      year: '2023'
    )
    expect(results).to be_an(Array)
  end

  it "sorts results" do
    results = described_class.filtered(sort_by: 'name', sort_order: 'desc')
    expect(results).to be_an(Array)
  end
end

RSpec.shared_examples "an API error response" do |status_code|
  it "returns #{status_code} status" do
    expect(last_response.status).to eq(status_code)
  end

  it "returns JSON error message" do
    body = JSON.parse(last_response.body)
    expect(body).to have_key('error')
  end
end

RSpec.shared_examples "handles database errors gracefully" do
  it "handles connection errors" do
    allow(DB).to receive(:[]).and_raise(Sequel::DatabaseConnectionError.new("Connection failed"))
    expect { subject }.not_to raise_error
  end

  it "handles query errors" do
    allow(DB).to receive(:[]).and_raise(Sequel::DatabaseError.new("Query failed"))
    expect { subject }.not_to raise_error
  end
end
