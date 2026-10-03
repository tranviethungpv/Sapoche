Pod::Spec.new do |s|
  s.name             = 'sapoche_native'
  s.version          = '0.0.1'
  s.summary          = 'The iOS native side of Sapoche.'
  s.description      = 'Player, room connection, YouTube access and library of Sapoche.'
  s.homepage         = 'https://github.com/tranviethungpv/Sapoche'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'Sapoche' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'sapoche_native/Sources/sapoche_native/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.libraries        = 'sqlite3'
end
