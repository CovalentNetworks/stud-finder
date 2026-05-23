# frozen_string_literal: true

require 'spec_helper'
require 'stud_finder'

RSpec.describe StudFinder do
  it 'loads the top-level entrypoint and exposes the version' do
    expect(described_class::VERSION).to be_a(String)
    expect(described_class::VERSION).not_to be_empty
  end
end
