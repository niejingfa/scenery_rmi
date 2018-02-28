module SceneryRmi
  unless self.respond_to?(:silence_warnings)
    def self.silence_warnings
      old_verbose, $VERBOSE = $VERBOSE, nil
      yield
    ensure
      $VERBOSE = old_verbose
    end
  end
  silence_warnings {
    VERSION = '3.0.0.2017052701'
  }
end
