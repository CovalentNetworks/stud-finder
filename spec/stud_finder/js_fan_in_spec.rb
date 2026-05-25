# frozen_string_literal: true

require 'spec_helper'
require 'stud_finder/js_fan_in'

RSpec.describe StudFinder::JsFanIn do
  def make_repo
    Dir.mktmpdir do |dir|
      system('git', 'init', '-q', dir)
      yield dir
    end
  end

  def write_file(root, relative, content = '')
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def write_depcruise(root, body)
    path = File.join(root, 'node_modules/.bin/depcruise')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    FileUtils.chmod('+x', path)
  end

  def call(root, files, js_timeout: 60, stderr: StringIO.new)
    described_class.new(repo_path: root, files: files, js_timeout: js_timeout, stderr: stderr).call
  end

  it 'counts incoming edges, deduplicates source-target pairs, and filters self/external deps' do
    make_repo do |root|
      files = %w[src/a.js src/b.ts src/c.jsx src/d.tsx]
      files.each { |file| write_file(root, file) }
      write_depcruise(root, <<~SH)
        #!/bin/sh
        cat <<'JSON'
        {"modules":[
          {"source":"./src/a.js","dependencies":[
            {"resolved":"./src/b.ts"},
            {"resolved":"./src/b.ts"},
            {"resolved":"./src/a.js"},
            {"resolved":"./node_modules/react/index.js"}]},
          {"source":"./src/c.jsx","dependencies":[{"resolved":"./src/b.ts"},{"resolved":"./src/d.tsx"}]},
          {"source":"./src/d.tsx","dependencies":[{"resolved":"./src/b.ts"}]}
        ]}
        JSON
      SH

      result = call(root, files)

      expect(result.warnings).to eq([])
      expect(result.counts).to include('src/a.js' => 0, 'src/b.ts' => 3, 'src/c.jsx' => 0, 'src/d.tsx' => 1)
    end
  end

  it 'degrades when node is missing' do
    make_repo do |root|
      files = %w[src/a.js src/b.js]
      allow(Open3).to receive(:capture3).with('node', '--version').and_raise(Errno::ENOENT)
      stderr = StringIO.new

      result = call(root, files, stderr: stderr)

      expect(result.counts.values).to all(eq(0))
      expect(result.warnings).to eq(['js_tools_missing'])
      expect(stderr.string).to include('js_tools_missing')
    end
  end

  it 'degrades when dependency-cruiser is missing' do
    make_repo do |root|
      files = %w[src/a.js src/b.js]
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).with('node', '--version').and_return(['v24.0.0', '', status])
      original_path = ENV.fetch('PATH', nil)
      ENV['PATH'] = ''

      result = call(root, files)

      expect(result.counts.values).to all(eq(0))
      expect(result.warnings).to eq(['js_tools_missing'])
    ensure
      ENV['PATH'] = original_path
    end
  end

  it 'degrades on malformed JSON and non-zero exit' do
    make_repo do |root|
      files = %w[src/a.js src/b.js]
      files.each { |file| write_file(root, file) }
      write_depcruise(root, "#!/bin/sh\nprintf '{nope'\n")

      malformed = call(root, files)
      expect(malformed.counts.values).to all(eq(0))
      expect(malformed.warnings).to eq(['js_tools_missing'])

      write_depcruise(root, "#!/bin/sh\nexit 2\n")
      nonzero = call(root, files)
      expect(nonzero.counts.values).to all(eq(0))
      expect(nonzero.warnings).to eq(['js_tools_missing'])
    end
  end

  it 'degrades on timeout' do
    make_repo do |root|
      files = %w[src/a.js src/b.js]
      files.each { |file| write_file(root, file) }
      write_depcruise(root, "#!/bin/sh\necho '{}'\n")
      allow(Timeout).to receive(:timeout).and_raise(Timeout::Error)
      stderr = StringIO.new

      result = call(root, files, js_timeout: 1, stderr: stderr)

      expect(result.counts.values).to all(eq(0))
      expect(result.warnings).to eq(['js_depcruise_timeout'])
      expect(stderr.string).to include('js_depcruise_timeout')
    end
  end
end
