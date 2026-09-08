require 'rake/testtask'

# test_differential needs a separately built checkout of the old C scanner as
# an oracle (see test/differential_helper.rb); it is a development tool, not
# part of the default suite.
Rake::TestTask.new(:test) do |t|
  t.libs = %w[lib test]
  t.test_files = FileList['test/test_*.rb'].exclude(/differential/)
  t.verbose = true
end

Rake::TestTask.new(:differential) do |t|
  t.libs = %w[lib test]
  t.test_files = FileList['test/test_differential.rb']
  t.verbose = true
end

desc 'Assert the suite produces identical results across 20 runs'
task :determinism do
  results = 20.times.map do
    `ruby -Ilib -Itest test/test_parser.rb 2>&1`[/\d+ failures, \d+ errors/]
  end.tally
  abort "non-deterministic: #{results.inspect}" if results.size != 1
  puts "deterministic across 20 runs: #{results.keys.first}"
end

desc 'Assert every fixture round-trips byte-identically'
task :fidelity do
  $LOAD_PATH.unshift('lib')
  require 'hpricot'
  files = Dir['test/files/*'].select { |f| File.file?(f) }
  # Compared as bytes: src comes from binread (ASCII-8BIT) while output
  # carries the document's encoding, and String#== is false across
  # incompatible encodings even when the bytes match.
  bad = files.reject do |f|
    src = File.binread(f)
    Hpricot::XML(src).to_original_html.b == src.b
  end
  abort "not byte-identical: #{bad.inspect}" unless bad.empty?
  puts "#{files.size} fixtures round-trip byte-identically"
end

task default: %i[test fidelity determinism]
