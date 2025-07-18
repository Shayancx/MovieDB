# frozen_string_literal: true

require 'spec_helper'
require_relative '../../app/services/statistics_service'

RSpec.describe StatisticsService do
  let(:db) { mock_db_connection }
  let(:mock_dataset) { double('mock_dataset') }

  before do
    stub_const('DB', db)
    allow(db).to receive(:[]).and_return(mock_dataset)
    allow(mock_dataset).to receive(:count).and_return(10)
    allow(mock_dataset).to receive(:sum).with(:file_size_mb).and_return(20480) # 20 GB
    allow(mock_dataset).to receive(:sum).with(:runtime_minutes).and_return(1200) # 20 hours
    allow(mock_dataset).to receive(:join).and_return(mock_dataset)
    allow(mock_dataset).to receive(:group_and_count).and_return(mock_dataset)
    allow(mock_dataset).to receive(:order).and_return(mock_dataset)
    allow(mock_dataset).to receive(:limit).and_return(mock_dataset)
    allow(mock_dataset).to receive(:where).and_return(mock_dataset)
    allow(mock_dataset).to receive(:all).and_return([])

    allow(PrettyLogger).to receive(:error)
  end

  describe '.summary' do
    it 'returns a hash of all statistics' do
      summary = described_class.summary
      expect(summary).to be_a(Hash)
      expect(summary.keys).to contain_exactly(
        :total_movies, :total_size_gb, :total_runtime_hours,
        :movies_per_genre, :movies_per_year
      )
    end
  end

  describe 'private methods' do
    describe '.total_movies' do
      it 'calculates the total number of movies' do
        expect(described_class.send(:total_movies)).to eq(10)
      end

      it 'returns 0 on database error' do
        allow(mock_dataset).to receive(:count).and_raise(Sequel::DatabaseError)
        expect(described_class.send(:total_movies)).to eq(0)
        expect(PrettyLogger).to have_received(:error)
      end
    end

    describe '.total_size_gb' do
      it 'calculates the total size in GB' do
        expect(described_class.send(:total_size_gb)).to eq(20.0)
      end

      it 'returns 0 if total size is nil' do
        allow(mock_dataset).to receive(:sum).with(:file_size_mb).and_return(nil)
        expect(described_class.send(:total_size_gb)).to eq(0)
      end
    end

    describe '.total_runtime_hours' do
      it 'calculates the total runtime in hours' do
        expect(described_class.send(:total_runtime_hours)).to eq(20)
      end

      it 'returns 0 if total runtime is nil' do
        allow(mock_dataset).to receive(:sum).with(:runtime_minutes).and_return(nil)
        expect(described_class.send(:total_runtime_hours)).to eq(0)
      end
    end

    describe '.movies_per_genre' do
      it 'returns an array of genre statistics' do
        allow(mock_dataset).to receive(:all).and_return([{ genre_name: 'Action', count: 5 }])
        genres = described_class.send(:movies_per_genre)
        expect(genres).to be_an(Array)
        expect(genres.first[:genre_name]).to eq('Action')
      end

      it 'returns an empty array on database error' do
        allow(mock_dataset).to receive(:all).and_raise(Sequel::DatabaseError)
        expect(described_class.send(:movies_per_genre)).to eq([])
        expect(PrettyLogger).to have_received(:error)
      end
    end

    describe '.movies_per_year' do
      it 'returns an array of year statistics' do
        allow(mock_dataset).to receive(:all).and_return([{ year: '2023', count: 8 }])
        years = described_class.send(:movies_per_year)
        expect(years).to be_an(Array)
        expect(years.first[:year]).to eq('2023')
      end

      it 'returns an empty array on database error' do
        allow(mock_dataset).to receive(:all).and_raise(Sequel::DatabaseError)
        expect(described_class.send(:movies_per_year)).to eq([])
        expect(PrettyLogger).to have_received(:error)
      end
    end
  end
end