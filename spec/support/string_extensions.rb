# Add simple singularize for tests
class String
  def singularize
    case self
    when 'genres' then 'genre'
    when 'countries' then 'country'
    when 'languages' then 'language'
    when 'franchises' then 'franchise'
    else self.sub(/s$/, '')
    end
  end
end
