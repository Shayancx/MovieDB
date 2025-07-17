# frozen_string_literal: true

require_relative '../db'

class PersonService
  class << self
    def find(person_id)
      person = DB[:people].where(person_id: person_id).first
      return nil unless person

      person[:movies] = DB[:movie_cast]
                        .join(:movies, movie_id: :movie_id)
                        .where(Sequel[:movie_cast][:person_id] => person_id)
                        .order(Sequel.desc(:release_date))
                        .select(Sequel[:movies][:movie_id], :movie_name, :release_date, :character_name, :poster_path)
                        .all
      person
    end
  end
end
