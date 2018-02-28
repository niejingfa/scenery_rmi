#encoding: utf-8
require 'scenery_rmi/entity/helper/locale'
module SceneryRmi::Entity::Helper
  module ControllerHelper
    attr_accessor :_jrmi_controller, :_jrmi_request

    delegate :request_forgery_protection_token, :params, :session, :cookies, :response, :headers,
             :flash, :action_name, :controller_name, :controller_path, :to => :_jrmi_controller , :allow_nil => true

    def assign_controller(controller)
      @_jrmi_controller = controller
    end

    attr_accessor :output_buffer

    def self.included(model)
      model.send(:include, ::SceneryRmi::Entity::Helper::Locale)
    end
  end
end