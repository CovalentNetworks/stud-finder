# frozen_string_literal: true

require 'spec_helper'
require 'stud_finder/fan_in'

RSpec.describe StudFinder::FanIn do
  def write_file(relative_path, content)
    path = File.join(repo_path, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def fan_in(files)
    described_class.new(repo_path: repo_path, files: files).call.counts
  end

  let(:repo_path) { Dir.mktmpdir('stud-finder-fan-in') }

  after do
    FileUtils.remove_entry(repo_path)
  end

  it 'counts how many other files reference the primary constant' do
    write_file('app/models/user.rb', 'class User; end')
    write_file('app/services/greet_user.rb', 'class GreetUser; User.new; end')

    counts = fan_in(['app/models/user.rb', 'app/services/greet_user.rb'])

    expect(counts['app/models/user.rb']).to eq(1)
    expect(counts['app/services/greet_user.rb']).to eq(0)
  end

  it 'maps concerns to the constant below the concerns directory' do
    write_file('app/models/concerns/auditable.rb', 'AUDITABLE = true')
    write_file('app/models/user.rb', 'class User; include Auditable; end')

    counts = fan_in(['app/models/concerns/auditable.rb', 'app/models/user.rb'])

    expect(counts['app/models/concerns/auditable.rb']).to eq(1)
  end

  it 'uses only the first top-level class or module as the primary constant' do
    write_file('app/models/multi.rb', <<~RUBY)
      class FirstConstant; end
      class SecondConstant; end
    RUBY
    write_file('app/services/uses_first.rb', 'class UsesFirst; FirstConstant.new; end')
    write_file('app/services/uses_second.rb', 'class UsesSecond; SecondConstant.new; end')

    counts = fan_in(['app/models/multi.rb', 'app/services/uses_first.rb', 'app/services/uses_second.rb'])

    expect(counts['app/models/multi.rb']).to eq(1)
  end

  it 'does not treat nested classes as primary constants' do
    write_file('app/models/foo.rb', <<~RUBY)
      class Foo
        class Bar; end
      end
    RUBY
    write_file('app/services/uses_foo.rb', 'class UsesFoo; Foo.new; end')
    write_file('app/services/uses_bar.rb', 'class UsesBar; Foo::Bar.new; end')

    counts = fan_in(['app/models/foo.rb', 'app/services/uses_foo.rb', 'app/services/uses_bar.rb'])

    expect(counts['app/models/foo.rb']).to eq(1)
  end

  it 'assigns zero fan_in to files outside app and lib' do
    write_file('test/models/user_test.rb', 'class UserTest; User.new; end')
    write_file('app/models/user.rb', 'class User; end')

    counts = fan_in(['test/models/user_test.rb', 'app/models/user.rb'])

    expect(counts['test/models/user_test.rb']).to eq(0)
  end

  it 'does not count a file reference to its own constant' do
    write_file('app/models/user.rb', 'class User; User.new; end')

    counts = fan_in(['app/models/user.rb'])

    expect(counts['app/models/user.rb']).to eq(0)
  end

  it 'silently ignores unknown or unresolvable constants' do
    write_file('app/models/user.rb', 'class User; end')
    write_file('app/services/uses_unknown.rb', 'class UsesUnknown; MissingConstant.new; end')

    expect { fan_in(['app/models/user.rb', 'app/services/uses_unknown.rb']) }.not_to raise_error
  end
end
