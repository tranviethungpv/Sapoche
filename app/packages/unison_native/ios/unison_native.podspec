Pod::Spec.new do |s|
  s.name             = 'unison_native'
  s.version          = '0.0.1'
  s.summary          = 'The iOS native side of Unison.'
  s.description      = 'Player, room connection, YouTube access and library of Unison.'
  s.homepage         = 'https://github.com/tranviethungpv/Unison'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'Unison' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'unison_native/Sources/unison_native/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.libraries        = 'sqlite3'
end
