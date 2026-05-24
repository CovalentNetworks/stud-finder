# frozen_string_literal: true

require 'spec_helper'
require 'stud_finder/file_collector'

RSpec.describe StudFinder::FileCollector do
  def make_repo
    Dir.mktmpdir do |dir|
      system('git', 'init', '-q', dir)
      yield dir
    end
  end

  def write_file(root, relative, content = "class Example\nend\n")
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def collect(root, excludes: [], min_files: 5, stderr: StringIO.new)
    described_class.new(path: root, excludes: excludes, min_files: min_files, stderr: stderr).collect
  end

  it 'filters default excludes and auto-generated files' do
    make_repo do |root|
      %w[app/models/user.rb app/models/account.rb app/models/order.rb app/models/invoice.rb
         app/models/payment.rb].each do |file|
        write_file(root, file)
      end
      write_file(root, 'db/schema.rb')
      write_file(root, 'db/migrate/20260101000000_create_users.rb')
      write_file(root, 'vendor/gem/lib/vendor_file.rb')
      write_file(root, 'tmp/cache/temp.rb')
      write_file(root, 'log/generated.rb')
      write_file(root, 'spec/models/user_spec.rb')
      write_file(root, 'test/models/user_test.rb')
      write_file(root, 'app/models/generated.rb', "\n# This file is auto-generated\nclass Generated\nend\n")

      result = collect(root)

      expect(result.files).to contain_exactly(
        'app/models/account.rb',
        'app/models/invoice.rb',
        'app/models/order.rb',
        'app/models/payment.rb',
        'app/models/user.rb'
      )
      expect(result.default_excluded_count).to eq(8)
    end
  end

  it 'applies custom exclude glob patterns relative to the repo path' do
    make_repo do |root|
      %w[app/models/user.rb app/models/account.rb app/models/order.rb app/services/billing.rb app/services/tax.rb
         app/admin/report.rb lib/keep.rb].each do |file|
        write_file(root, file)
      end

      result = collect(root, excludes: ['app/admin/**', 'app/models/o*.rb'])

      expect(result.files).to contain_exactly(
        'app/models/account.rb',
        'app/models/user.rb',
        'app/services/billing.rb',
        'app/services/tax.rb',
        'lib/keep.rb'
      )
      expect(result.custom_excluded_count).to eq(2)
    end
  end

  it 'includes JavaScript and TypeScript files with language tags and default test excludes' do
    make_repo do |root|
      %w[app/models/user.rb app/models/account.rb app/javascript/a.js app/javascript/b.jsx app/javascript/c.ts
         app/javascript/d.tsx].each do |file|
        write_file(root, file, file.end_with?('.rb') ? "class Example
end
" : 'export const value = 1;')
      end
      write_file(root, '__tests__/ignored.js', 'import x from "../app/javascript/a";')
      write_file(root, 'app/javascript/a.test.js', '')
      write_file(root, 'app/javascript/b.test.ts', '')
      write_file(root, 'app/javascript/c.spec.js', '')
      write_file(root, 'app/javascript/d.spec.ts', '')

      result = collect(root)

      expect(result.files).to include('app/javascript/a.js', 'app/javascript/b.jsx', 'app/javascript/c.ts',
                                      'app/javascript/d.tsx')
      expect(result.files).not_to include(
        '__tests__/ignored.js', 'app/javascript/a.test.js', 'app/javascript/b.test.ts',
        'app/javascript/c.spec.js', 'app/javascript/d.spec.ts'
      )
      expect(result.languages).to include(
        'app/models/user.rb' => :ruby,
        'app/javascript/a.js' => :javascript,
        'app/javascript/b.jsx' => :javascript,
        'app/javascript/c.ts' => :typescript,
        'app/javascript/d.tsx' => :typescript
      )
      expect(result.default_excluded_count).to eq(5)
    end
  end

  it 'raises for a missing path' do
    missing = File.join(Dir.tmpdir, "stud-finder-missing-#{rand(100_000)}")

    expect { collect(missing) }.to raise_error(StudFinder::FileCollector::Error, /does not exist/)
  end

  it 'raises when the path is not a git repository' do
    Dir.mktmpdir do |root|
      expect { collect(root) }.to raise_error(StudFinder::FileCollector::Error, /not a git repository/)
    end
  end

  it 'raises when git is not in PATH' do
    make_repo do |root|
      original_path = ENV.fetch('PATH', nil)
      ENV['PATH'] = ''
      expect { collect(root) }.to raise_error(StudFinder::FileCollector::Error, /git not found/)
    ensure
      ENV['PATH'] = original_path
    end
  end

  it 'errors when fewer than five Ruby files remain' do
    make_repo do |root|
      4.times { |i| write_file(root, "app/models/model_#{i}.rb") }

      expect do
        collect(root)
      end.to raise_error(StudFinder::FileCollector::Error,
                         /only 4 supported files found.*Too few for meaningful analysis/)
    end
  end

  it 'warns but continues when file count is below min_files' do
    make_repo do |root|
      5.times { |i| write_file(root, "app/models/model_#{i}.rb") }
      stderr = StringIO.new

      result = collect(root, min_files: 20, stderr: stderr)

      expect(result.files.length).to eq(5)
      expect(stderr.string).to include('Warning: only 5 files found')
    end
  end
end
