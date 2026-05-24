# frozen_string_literal: true

class AuthService
  def call
    User.new.active?
  end
end
