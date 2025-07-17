require 'spec_helper'

RSpec.describe 'MovieService' do
  before do
    dataset = Class.new do
      def order(*) = self
      def all = [:item]
      def exclude(*) = self
      def select(*) = self
      def distinct = self
      def map(&block)
        [{ year: 2021 }, { year: 2020 }].map(&block)
      end
    end

    db = Class.new do
      attr_reader :called_args
      def extension(*) = nil
      def test_connection = nil
      def fetch(sql, *args)
        @called_args = [sql, *args]
        Struct.new(:all, :first).new([{ id: 1 }], { id: 1 })
      end
      define_method(:[]) { |_| dataset.new }
    end.new
    allow(Sequel).to receive(:connect).and_return(db)
    load File.expand_path('../../../app/services/movie_service.rb', __FILE__)
    stub_const('DB', db)
    @db = db
  end


  describe '.genres' do
    it 'returns ordered genres' do
      expect(MovieService.genres).to eq([:item])
    end
  end

  describe '.filtered' do
    it 'builds SQL with search and genre filters and sorting' do
      MovieService.filtered(search: 'foo', genre: 'Action', sort_by: 'date', sort_order: 'desc')
      sql, *args = @db.called_args
      expect(sql).to include('m.movie_name ILIKE ?')
      expect(sql).to include('g.genre_name = ?')
      expect(sql).to include('ORDER BY m.release_date DESC')
      expect(args).to eq(['%foo%', '%foo%', 'Action'])
    end
  end

  describe '.years' do
    it 'returns sorted list of years as integers' do
      expect(MovieService.years).to eq([2021, 2020])
    end
  end
end
