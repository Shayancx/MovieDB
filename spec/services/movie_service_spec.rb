require 'spec_helper'

RSpec.describe 'MovieService' do
  before do
    db = Class.new do
      attr_reader :called_args
      def extension(*) = nil
      def test_connection = nil
      def fetch(sql, *args)
        @called_args = [sql, *args]
        Struct.new(:all, :first).new([{ id: 1 }], { id: 1 })
      end
      def [](_)
        Class.new do
          def order(*) = self
          def all = [:item]
        end.new
      end
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
end
