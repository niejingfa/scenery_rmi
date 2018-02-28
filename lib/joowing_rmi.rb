#encoding: utf-8
require 'rubygems'
require 'joowing_rmi/version'
require 'delegate'
require 'fileutils'
require 'digest'
require 'redis'
require 'redis/namespace'
require 'grape-entity'
require 'active_support/all'
require 'active_resource'
require 'action_view'
require 'will_paginate'
require 'will_paginate/collection'
require 'faraday'

module JoowingRmi
  require 'joowing_rmi/erb_yaml'
  require 'joowing_rmi/http_pool'
  require 'joowing_rmi/entity'
  require 'joowing_rmi/origin'
  require 'joowing_rmi/connection_manager'
  require 'joowing_rmi/connection'
  require 'joowing_rmi/manager'
  require 'joowing_rmi/x_request'
  require 'joowing_rmi/runtime'
  require 'joowing_rmi/faraday_response'


  module Definition
    require 'joowing_rmi/definition/dsl'
    require 'joowing_rmi/definition/module_definition'
    require 'joowing_rmi/definition/class_definition'
    require 'joowing_rmi/definition/attribute_definition'
    require 'joowing_rmi/definition/action_definition'
  end

  module Ext

  end

  # 特定常量的定义未找到的错误
  class ConfigNotFoundError < StandardError

  end


  mattr_accessor :after_initialize_blks

  class << self

    def initialize_rmi(backend = nil)
      backend ||= JoowingRmi.joowing_platform_spec['name']
      config = JoowingRmi.joowing_platform_spec['joowing_rmi']
      raise "There is no joowing_rmi config for #{ENV['RACK_ENV'] || ENV['RAILS_ENV'] } env in config/joowing_platform.yml" unless config
      Manager.application ||= Manager.new(config)
      if backend
        Manager.backend = backend
        Manager.application.backend = backend
      end
      yield Manager.application if block_given?
      (self.after_initialize_blks || []).each { |blk| blk.call(Manager.application) }
    end

    def after_initialize(&blk)
      if Manager.application != nil
        blk.call(Manager.application)
      else
        self.after_initialize_blks ||= []
        self.after_initialize_blks << blk
      end
    end

    def define_rmi_class(name, &blk)
      c = Class.new(ActiveResource::Base)
      c.send(:include, JoowingRmi::Obj::Base)
      blk.call(c) if blk
      JoowingRmi::Obj.const_set(name, c)
    end

    # 在特定用户session上下文中执行joowing rmi请求
    def with_session(session_id)
      xid = XRequest::X_SESSION_ID
      env = XRequest.env
      origin_session_id = env[xid]
      env[xid] = session_id
      yield
      env[xid] = origin_session_id
    end

    #
    # ==Register a callback which will be called when specified model is defined
    #
    # @param config_name: like app_backend.newbee_config.link_group
    # @param block with one arg, which receive the defined model or class
    #
    def defined(config_name, &block)
      begin
        model = Manager.application.look_for_module_or_class(config_name)
      rescue ConfigNotFoundError
        model = nil
      end
      if model
        block.call(model)
      else
        Manager.application.after_model_blks[config_name] ||= []
        Manager.application.after_model_blks[config_name] << block
      end
    end

    #
    # == 提供给joowing_api/xxx_api等gem注册dsl的方法
    #
    # @param folder: 需要进行扫描的dsl所在目录，支持多层目录
    #
    def scan(folder)
      JoowingRmi.after_initialize do |manager|
        files = Dir.glob(File.join(folder, '**/*.rb'))
        files.sort! # ensure parent file is previous than sub module files
        files.each do |file|
          manager.logger.debug "Require: #{file}"
          # don not eat any exception
          require file
        end
      end
    end

    # 系统启动后, 通过Redis的消息, 发布特定目录所有的api版本信息
    #  以便通知所有依赖相应API的系统, 确定是否要进行API对象Reload
    def publish(folder)
      JoowingRmi.after_initialize do |manager|
        redis = Redis.new(manager.config[:redis].symbolize_keys)
        redis.call 'client', 'setname', "joowing_rmi_publisher_of_#{$$}" rescue nil
        files = Dir.glob(File.join(folder, '**/*.rb'))
        files.sort! # ensure parent file is previous than sub module files
        files.each do |file|
          name = file[folder.length + 1 .. -4] # -4: remove .rb
          names = name.split('/')
          names.unshift JoowingRmi::Manager.backend
          names.unshift 'joowing_rmi'
          name = names.join('.')
          version = Digest::MD5.hexdigest(IO.read(file))
          redis.publish name, version
        end
        redis.quit # low/high version
      end
    end

    def joowing_platform_spec
      @spec ||= begin
        platform = ErbYaml.load File.new('config/joowing_platform.yml')
        platform && platform[ENV['RAILS_ENV'] || ENV['RACK_ENV'] || 'development']
      rescue
        {'name' => 'unknown', 'joowing_rmi' => {}}
      end
    end

  end

  module Obj
    require 'joowing_rmi/obj/base'
  end
end

# Make the Joowing RMI DSL available in main
# OPTIMIZE it with context object
include JoowingRmi::Definition::DSL

def joowing_rmi_initialize
  require 'joowing'
  app = JoowingRmi::Manager.application
  # when it's trigger by ActiveSupport Reloader, previous than the JoowingRmi.initialize_rmi
  return unless app
  app.backends.clear
  app.initialize_backend_constants
end

if defined?(ActiveSupport::Reloader)
  ActiveSupport::Reloader.to_prepare do
    silence_warnings { joowing_rmi_initialize }
  end
end

JoowingRmi.after_initialize { joowing_rmi_initialize }
