require 'spec_helper'

RSpec.describe 'PersonService' do
  before do
    db = Class.new do
      attr_reader :captured
      def extension(*) = nil
      def test_connection = nil
      def [](_)
        self
      end
      def where(*args)
        @captured = args
        self
      end
      def join(*); self; end
      def first
        { person_id: 1 }
      end
      def order(*)
        self
      end
      def select(*)
        self
      end
      def all
        [{ movie_id: 1 }]
      end
    end.new
    allow(Sequel).to receive(:connect).and_return(db)
    load File.expand_path('../../../app/services/person_service.rb', __FILE__)
    stub_const('DB', db)
    @db = db
  end

  it 'returns person details with movies' do
    person = PersonService.find(1)
    expect(person[:movies].first[:movie_id]).to eq(1)
    expect(@db.captured.first.values.first).to eq(1)
  end
end
