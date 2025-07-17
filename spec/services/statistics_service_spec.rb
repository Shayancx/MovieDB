require 'spec_helper'

RSpec.describe 'StatisticsService' do
  before do
    db = Class.new do
      def extension(*) = nil
      def test_connection = nil
      def [](_); self; end
      def count; 10; end
      def sum(_); 100; end
      def join(*); self; end
      def group_and_count(*); self; end
      def order(*)
        self
      end
      def limit(*)
        self
      end
      def where(&block)
        self
      end
      def select(*); self; end
      def map(&block)
        [2020]
      end
      def all
        [{ genre_name: 'Action', count: 2 }]
      end
    end.new
    allow(Sequel).to receive(:connect).and_return(db)
    load File.expand_path('../../../app/services/statistics_service.rb', __FILE__)
    stub_const('DB', db)
  end

  it 'returns summary hash with computed values' do
    summary = StatisticsService.summary
    expect(summary[:total_movies]).to eq(10)
    expect(summary[:total_size_gb]).to eq((100 / 1024.0).round(2))
    expect(summary[:movies_per_genre]).to be_a(Array)
  end
end
