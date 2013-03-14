# -*- encoding: utf-8 -*-
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'skyeye/version'

Gem::Specification.new do |gem|
  gem.name          = "skyeye"
  gem.version       = Skyeye::VERSION
  gem.authors       = ["Greg Fodor"]
  gem.email         = ["gfodor@gmail.com"]
  gem.description   = %q{SkyEye is a daemon that lets you have nagios-like alerts on EC2 using CloudWatch.}
  gem.summary   = %q{SkyEye is a daemon that lets you have nagios-like alerts on EC2 using CloudWatch.}
  gem.homepage      = "http://github.com/gfodor/skyeye"

  gem.files         = `git ls-files`.split($/)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.require_paths = ["lib"]
end
