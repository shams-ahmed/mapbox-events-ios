Pod::Spec.new do |s|

  # ―――  Spec Metadata  ―――――――――――――――――――――――――――――――――――――――――――――――――――――――――― #

  s.name = 'MapboxMobileEvents'
  s.version = "1.2.3"
  s.summary = "Mapbox Mobile Events"

  s.description  = "Collects usage information to help Mapbox improve its products."

  s.homepage = "https://www.mapbox.com/"

  # ―――  Spec License  ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――― #

  s.license = { :type => "ISC", :file => "LICENSE.md" }

  # ――― Author Metadata  ――――――――――――――――――――――――――――――――――――――――――――――――――――――――― #

  s.author = { "Mapbox" => "mobile@mapbox.com" }
  # s.social_media_url = "https://twitter.com/mapbox"

  # ――― Platform Specifics ――――――――――――――――――――――――――――――――――――――――――――――――――――――― #

  s.ios.deployment_target = "9.0"

  # ――― Source Location ―――――――――――――――――――――――――――――――――――――――――――――――――――――――――― #

  s.source = {
    :git => 'https://github.com/shams-ahmed/mapbox-events-ios.git', :tag => 'v1.2.3'
  }

  s.source_files = 'Sources/MapboxMobileEvents/**/*.{h,m}'

  s.pod_target_xcconfig = { 
    'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_ROOT}/Sources/MapboxMobileEvents/include"',
  }

  # spec.header_mappings_dir = 'TSKit/include/**/*.h'


  # ――― Project Settings ――――――――――――――――――――――――――――――――――――――――――――――――――――――――― #

  s.requires_arc = true
  s.module_name = s.name

end
