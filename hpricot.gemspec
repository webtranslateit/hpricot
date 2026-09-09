Gem::Specification.new do |s|
  s.name = 'webtranslateit-hpricot'
  s.version = '1.0.1'

  s.authors = ['why the lucky stiff', 'WebTranslateIt']
  s.email = 'support@webtranslateit.com'
  s.summary = 'A liberal HTML/XML parser with byte-identical round-tripping'
  s.description = <<~DESC
    A maintained fork of why the lucky stiff's hpricot. Parses malformed markup
    liberally and preserves the exact source bytes of anything it did not
    modify, so numeric character references, entity spellings and attribute
    order all survive a parse/serialize round trip. Pure Ruby, no native
    extension.
  DESC
  s.homepage = 'https://github.com/webtranslateit/hpricot'
  s.license = 'MIT'

  s.required_ruby_version = '>= 3.3'
  s.require_paths = ['lib']
  s.extra_rdoc_files = ['README.md', 'CHANGELOG', 'COPYING']

  s.files = `git ls-files -z`.split("\x0").reject do |f|
    f.start_with?('docs/', 'test/', '.github/') || f == '.gitignore'
  end

  s.metadata = {
    'source_code_uri' => 'https://github.com/webtranslateit/hpricot',
    'bug_tracker_uri' => 'https://github.com/webtranslateit/hpricot/issues',
    'changelog_uri' => 'https://github.com/webtranslateit/hpricot/blob/master/CHANGELOG',
    'rubygems_mfa_required' => 'true'
  }

  s.add_development_dependency 'rake', '>= 13.0'
  s.add_development_dependency 'test-unit', '~> 3.7'
end
