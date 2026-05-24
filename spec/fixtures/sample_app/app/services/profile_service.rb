# frozen_string_literal: true

class ProfileService
  def call
    Profile.new
    User.new
  end
end
