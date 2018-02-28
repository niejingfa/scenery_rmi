# Make ActiveResource::LogSubscriber happy
module Faraday
  class Response
    def code
      self.status
    end

    def message
      self.body.to_s
    end
  end
end
