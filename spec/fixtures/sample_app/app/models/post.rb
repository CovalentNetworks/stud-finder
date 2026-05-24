# frozen_string_literal: true

class Post
  def author
    User.new
  end
end
