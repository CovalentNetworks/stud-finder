# frozen_string_literal: true

class PostService
  def call
    [User.new, Post.new]
  end
end
